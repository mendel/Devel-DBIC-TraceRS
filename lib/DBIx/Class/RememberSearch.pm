package DBIx::Class::RememberSearch;

use strict;
use warnings;

use base qw(DBIx::Class);

use Devel::StackTrace ();
use Sub::Name ();
use Devel::Symdump ();
use Scalar::Util ();

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

  foreach my $method (@search_methods) {
    my $orig_method = \&$method;
    *$method = Sub::Name::subname $method => sub {
      my $self = shift;

      my (@ret, $ret);
      if (wantarray) {
        @ret = $self->$orig_method(@_);
      } elsif (defined wantarray) {
        $ret = $self->$orig_method(@_);
      } else {
        $self->$orig_method(@_);
      }

      #FIXME append only once the same caller info (b/c eg. search calls search_rs, so the outer caller info is added twice)
      $ret->_search_stacktrace([
        @{$self->_search_stacktrace || []},
        Devel::StackTrace->new(
          frame_filter => sub { shift->{caller}->[0] !~ /^DBIx::Class/ },
          no_refs => 1,
        ),
      ]);

      return
        wantarray
          ? @ret
          : defined wantarray
            ? $ret
            : ();
    };
  }

  foreach my $method (@all_methods) {
    my $orig_method = \&$method;
    *$method = Sub::Name::subname $method => sub {
      my $self = shift;

      warn caller(2);
      my (@ret, $ret);
      if (wantarray) {
        @ret = eval { $self->$orig_method(@_); };
      } elsif (defined wantarray) {
        $ret = eval { $self->$orig_method(@_); };
      } else {
        eval { $self->$orig_method(@_); };
      }
      if ($@ ne '') {
        #FIXME cleanly append to the message (probably wrapped in an exception object)
        #FIXME append only once
        if (Scalar::Util::blessed $self) {
          die join("\n", $@, map { $_->as_string } @{$self->_search_stacktrace});
        } else {
          die;  # propagate
        }
      }

      return
        wantarray
          ? @ret
          : defined wantarray
            ? $ret
            : ();
    };
  }
}

1;
