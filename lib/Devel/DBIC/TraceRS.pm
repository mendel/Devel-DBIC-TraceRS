package Devel::DBIC::TraceRS;

#FIXME tests
#FIXME documentation
#FIXME module build

use strict;
use warnings;

use Devel::StackTrace;
use Sub::Name;
use Devel::Symdump;
use Scalar::Util qw(blessed);
use Context::Preserve;
use Devel::MonkeyPatch;

# make sure they are loaded so that we can monkey-patch them
use DBIx::Class::Schema;
use DBIx::Class::ResultSet;
use DBIx::Class::ResultSource;

#
# Returns the Devel::StackTrace object.
#
sub current_search_stacktrace()
{
  return Devel::StackTrace->new(
    ignore_class => [__PACKAGE__, qw(Context::Preserve Devel::MonkeyPatch)],
    no_refs => 1,
  );
}

DBIx::Class::ResultSet->mk_group_accessors(simple => qw(
  _tracers_stacktraces
  _tracers_stacktrace_appended_to_msg
  _tracers_stacktrace_captured
));

my @all_resultset_methods =
  grep { /^DBIx::Class::ResultSet::[a-z][^:]*$/ }
    Devel::Symdump->new("DBIx::Class::ResultSet")->functions;

my @traced_resultset_methods =
  grep { /^DBIx::Class::ResultSet::(new|search.*|related_resultset|slice|page)$/ }
    @all_resultset_methods;

my @other_traced_methods = qw(
  DBIx::Class::Schema::resultset
  DBIx::Class::ResultSource::resultset
);

# wrap all traced methods so we can capture the stacktrace
foreach my $method (@traced_resultset_methods, @other_traced_methods) {
  monkeypatch $method => sub {
    my $self = shift;
    my $args = \@_;

    my $self_isa_dbic_resultset =
      blessed($self) && $self->isa('DBIx::Class::ResultSet');

    # do not capture stacktraces of nested calls to traced methods
    # (eg. search() calls search_rs() internally)
    my $tracers_stacktrace_captured =
      $self_isa_dbic_resultset && $self->_tracers_stacktrace_captured;
    local $self->{_tracers_stacktrace_captured} = 1
      if $self_isa_dbic_resultset;

    return preserve_context { $self->original::method(@$args) }
      after => sub {
        my ($ret) = @_;

        $ret->_tracers_stacktraces([
          @{$self_isa_dbic_resultset && $self->_tracers_stacktraces || []},
          current_search_stacktrace()
        ]) if blessed($ret) && $ret->isa('DBIx::Class::ResultSet');
      };
  };
}

# wrap all methods to rewrite exceptions thrown from them
foreach my $method (@all_resultset_methods) {
  monkeypatch $method => sub {
    my $self = shift;

    if (blessed($self) && !$self->_tracers_stacktrace_appended_to_msg) {
      # do not append the stacktrace to the message more than once
      local $self->{_tracers_stacktrace_appended_to_msg} = 1;

      local *DBIx::Class::Schema::throw_exception =
        \&DBIx::Class::Schema::throw_exception;
      monkeypatch *DBIx::Class::Schema::throw_exception => sub {
        my $schema = shift;

        if (!blessed($_[0]) && $schema->stacktrace) {
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

        return $schema->original::method(@_);
      };

      return $self->original::method(@_);
    } else {
      return $self->original::method(@_);
    }
  };
}

1;
