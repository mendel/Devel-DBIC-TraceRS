package DBIx::Class::RememberSearch;

use strict;
use warnings;

use base qw(DBIx::Class);

use Carp::Clan qw/^DBIx::Class/;

use Devel::StackTrace;
use Sub::Name;
use Devel::Symdump;
use Scalar::Util;
use Tie::IxHash;

use DBIx::Class::ResultSet;

DBIx::Class::ResultSet->mk_group_accessors(simple => qw(
  _search_stacktraces
  _search_stacktraces_appended
));

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

        if (Scalar::Util::blessed $self && $schema->stacktrace && !$self->_search_stacktraces_appended) {
          $self->_search_stacktraces_appended(1);
          # output only once the same caller info (b/c eg. search() calls
          # search_rs(), so the outer caller info is added twice)
          tie my %seen_stacktraces, 'Tie::IxHash';
          foreach my $stacktrace (@{$self->_search_stacktraces}) {
            @seen_stacktraces{ join("\n", map { $_->as_string } $stacktrace->frames) } = ();
          }
          my $stacktraces = join("\n", "", keys %seen_stacktraces);
          $stacktraces =~ s/\n/\n\t/g;
          $_[0] .= "\nSearch calls:$stacktraces\n";
        }

        return $schema->$orig_throw_exception(@_);
      };

      return $self->$orig_method(@_);
    };
  }

  *DBIx::Class::ResultSet::_append_to_search_stacktrace = subname _append_to_search_stacktrace => sub {
    my $self = shift;

    $self->_search_stacktraces([
      @{$self->_search_stacktraces || []},
      Devel::StackTrace->new(
        frame_filter => sub { shift->{caller}->[0] !~ /^DBIx::Class/ },
        no_refs => 1,
      ),
    ]);
  };
}

1;
