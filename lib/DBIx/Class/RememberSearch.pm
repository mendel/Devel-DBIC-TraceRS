package DBIx::Class::RememberSearch;

use strict;
use warnings;

use base qw(DBIx::Class);

use Devel::StackTrace;
use Sub::Name;
use Devel::Symdump;
use Scalar::Util;

use DBIx::Class::ResultSet;

DBIx::Class::ResultSet->mk_group_accessors(simple => qw(_search_stacktrace));

{
  no strict 'refs';
  no warnings 'redefine';

  my @all_methods =
    grep { /^DBIx::Class::ResultSet::[a-z]/ }
      Devel::Symdump->new("DBIx::Class::ResultSet")->functions;

  my @search_methods =
    grep { /^DBIx::Class::ResultSet::.*search.*/ } @all_methods;

  # wrap new() so that $schema->resultset(...) is remembered
  foreach my $method (qw(DBIx::Class::ResultSet::new)) {
    my $orig_method = \&$method;
    *$method = subname $method => sub {
      my $class = shift;

      my (@ret, $self);
      if (wantarray) {
        @ret = $class->$orig_method(@_);
      } elsif (defined wantarray) {
        $self = $class->$orig_method(@_);
      } else {
        $class->$orig_method(@_);
      }

      $self->_append_to_search_stacktrace if $self;

      return
        wantarray
          ? @ret
          : defined wantarray
            ? $self
            : ();
    };
  }

  # wrap all search methods so that they are remembered
  foreach my $method (@search_methods) {
    my $orig_method = \&$method;
    *$method = subname $method => sub {
      my $self = shift;

      my (@ret, $ret);
      if (wantarray) {
        @ret = $self->$orig_method(@_);
      } elsif (defined wantarray) {
        $ret = $self->$orig_method(@_);
      } else {
        $self->$orig_method(@_);
      }

      $self->_append_to_search_stacktrace;

      return
        wantarray
          ? @ret
          : defined wantarray
            ? $ret
            : ();
    };
  }

  # wrap all methods to rewrite exceptions thrown from them
  foreach my $method (@all_methods) {
    my $orig_method = \&$method;
    *$method = subname $method => sub {
      my $self = shift;

      my $orig_throw_exception = \&DBIx::Class::Schema::throw_exception;
      local *DBIx::Class::Schema::throw_exception = subname throw_exception => sub {
        my $schema = shift;

        $_[0] = join("\n", $_[0], map { $_->as_string } @{$self->_search_stacktrace})
          if Scalar::Util::blessed $self;

        return $schema->$orig_throw_exception(@_);
      };

      return $self->$orig_method(@_);
    };
  }

  *DBIx::Class::ResultSet::_append_to_search_stacktrace = subname _append_to_search_stacktrace => sub {
    my $self = shift;

    #FIXME append only once the same caller info (b/c eg. search calls search_rs, so the outer caller info is added twice)
    $self->_search_stacktrace([
      @{$self->_search_stacktrace || []},
      Devel::StackTrace->new(
        frame_filter => sub { shift->{caller}->[0] !~ /^DBIx::Class/ },
        no_refs => 1,
      ),
    ]);
  };
}

1;
