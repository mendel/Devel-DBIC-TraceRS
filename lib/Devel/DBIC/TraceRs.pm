package Devel::DBIC::TraceRs;

use strict;
use warnings;

use Devel::StackTrace;
use Sub::Name;
use Devel::Symdump;
use Scalar::Util qw(blessed);

# make sure they are loaded so that we can monkey-patch them
use DBIx::Class::Schema;
use DBIx::Class::ResultSet;

#
# Monkey-patches the given sub (can be a glob or a bareword).
#
sub monkeypatch(*&)
{
  no strict 'refs';
  no warnings 'redefine';

  *{$_[0]} = subname $_[0] => $_[1];
}

#
# Returns the Devel::StackTrace object.
#
sub current_search_stacktrace()
{
  return Devel::StackTrace->new(
    ignore_class => __PACKAGE__,
    no_refs => 1,
  );
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

# wrap constructors (they will be traced, but must be handled a bit differently)
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

    $self->_tracers_stacktraces([ current_search_stacktrace() ]) if $self;

    return
      wantarray
        ? @ret
        : defined wantarray
          ? $self
          : ();
  };
}

# wrap all traced methods
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
      current_search_stacktrace()
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

    return $self->$orig_method(@_) unless blessed($self);

    # stop stacktraces after the outmost nested DBIx::Class::ResultSet call
    # (b/c eg.  search() calls search_rs() internally)
    my $tracers_stacktrace_appended_to_msg =
        $self->_tracers_stacktrace_appended_to_msg;
    local $self->{_tracers_stacktrace_appended_to_msg} = 1;

    my $orig_throw_exception = \&DBIx::Class::Schema::throw_exception;
    monkeypatch local *DBIx::Class::Schema::throw_exception => sub {
      my $schema = shift;

      if ($schema->stacktrace) {
        my $stacktraces = join("\n---\n",
          map {
            join("\n", map { $_->as_string } $_->frames)
          } @{$self->_tracers_stacktraces}
        );
        $stacktraces =~ s/^/  | /mg;

        $_[0] .= "\n"
               . "[ +- search calls ----\n"
               . "$stacktraces\n"
               . "  +------------------- ]";
      }

      return $schema->$orig_throw_exception(@_);
    } if !$tracers_stacktrace_appended_to_msg;

    return $self->$orig_method(@_);
  };
};

1;
