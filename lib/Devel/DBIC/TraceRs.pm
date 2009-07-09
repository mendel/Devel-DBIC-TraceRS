package Devel::DBIC::TraceRs;

use strict;
use warnings;

use Devel::StackTrace;
use Sub::Name;
use Devel::Symdump;
use Scalar::Util;

# make sure it's loaded so that we can monkey-patch it
use DBIx::Class::ResultSet;

sub monkeypatch(*&)
{
  no strict 'refs';
  no warnings 'redefine';

  *{$_[0]} = subname $_[0] => $_[1];
}

DBIx::Class::ResultSet->mk_group_accessors(simple => qw(
  _tracers_stacktraces
  _tracers_stacktrace_appended_to_msg
  _tracers_stacktrace_captured
));

my @all_methods =
  grep { /^DBIx::Class::ResultSet::[a-z]/ }
    Devel::Symdump->new("DBIx::Class::ResultSet")->functions;

my @constructor_methods = qw(
  DBIx::Class::ResultSet::new
  DBIx::Class::Schema::resultset
);

my @traced_methods =
  grep { /^DBIx::Class::ResultSet::(search.*|related_resultset|slice|page)$/ }
    @all_methods;

foreach my $method (@constructor_methods) {
  my $orig_method = \&$method;
  monkeypatch $method => sub {
    my $proto = shift;

    my (@ret, $self);
    if (wantarray) {
      @ret = $proto->$orig_method(@_);
    } elsif (defined wantarray) {
      $self = $proto->$orig_method(@_);
    } else {
      $proto->$orig_method(@_);
    }

    $self->_tracers_stacktraces([
      $self->_current_search_stacktrace
    ]) if $self;

    return
      wantarray
        ? @ret
        : defined wantarray
          ? $self
          : ();
  };
}

# wrap all search methods so that they are remembered
foreach my $method (@traced_methods) {
  my $orig_method = \&$method;
  monkeypatch $method => sub {
    my $self = shift;

    my $tracers_stacktrace_captured = $self->_tracers_stacktrace_captured;
    local $self->{_tracers_stacktrace_captured} = 1;

    my (@ret, $ret);
    if (wantarray) {
      @ret = $self->$orig_method(@_);
    } elsif (defined wantarray) {
      $ret = $self->$orig_method(@_);
    } else {
      $self->$orig_method(@_);
    }

    $ret->_tracers_stacktraces([
      @{$self->_tracers_stacktraces || []},
      $self->_current_search_stacktrace
    ]) if $ret && !$tracers_stacktrace_captured;

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
  monkeypatch $method => sub {
    my $self = shift;

    # only append the search stacktraces in the outmost nested call (b/c eg.
    # search() calls search_rs() internally)
    my $tracers_stacktrace_appended_to_msg =
      Scalar::Util::blessed($self) &&
        $self->_tracers_stacktrace_appended_to_msg;
    local $self->{_tracers_stacktrace_appended_to_msg} = 1
      if Scalar::Util::blessed($self);

    my $orig_throw_exception = \&DBIx::Class::Schema::throw_exception;
    monkeypatch local *DBIx::Class::Schema::throw_exception => sub {
      my $schema = shift;

      if ($schema->stacktrace && Scalar::Util::blessed($self) &&
          !$tracers_stacktrace_appended_to_msg) {
        my $stacktraces = "\n" . join("\n---\n",
          map {
            join("\n", map { $_->as_string } $_->frames)
          } @{$self->_tracers_stacktraces}
        );
        $stacktraces =~ s/\n/\n  | /g;
        $_[0] .= "\n"
               . "[ +- search calls ----"
               . "$stacktraces\n"
               . "  +------------------- ]";
      }

      return $schema->$orig_throw_exception(@_);
    };

    return $self->$orig_method(@_);
  };
};

monkeypatch DBIx::Class::ResultSet::_current_search_stacktrace => sub {
  my $self = shift;

  return Devel::StackTrace->new(
    ignore_class => __PACKAGE__,
    no_refs => 1,
  );
};

1;
