package Devel::DBIC::TraceRS;

#FIXME tests
#FIXME documentation
#FIXME module build

use strict;
use warnings;

use 5.005;

=head1 NAME

Devel::DBIC::TraceRS - When it blows up, let me know where a given DBIx::Class::ResultSet was built.

=head1 SYNOPSIS

  perl -MDevel::DBIC::TraceRS somescript.pl

=head1 DISCLAIMER

This is ALPHA SOFTWARE. Use at your own risk. Features may change.

=head1 DESCRIPTION



=head1 METHODS

=cut

our $VERSION = 0.01;

use Devel::StackTrace;
use Sub::Name;
use Devel::Symdump;
use Scalar::Util qw(blessed);
use Context::Preserve;
use Devel::MonkeyPatch::Method;

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
    ignore_class => [
      __PACKAGE__, qw(Context::Preserve Devel::MonkeyPatch::Method)
    ],
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

__END__

=head1 BUGS, CAVEATS AND NOTES

=head2 Performance

It monkey-patches all methods of L<DBIx::Class::ResultSet> and some methods of
other L<DBIx::Class> parts. Consequently it hurts performance and may make the
code unstable. This module is only meant to be used while you're developing the
code. B<Do not use this module in production!>

=head1 SEE ALSO

L<DBIx::Class>, L<Devel::StackTrace>

=head1 SUPPORT

Please submit bugs to the CPAN RT system at
http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Devel%3A%3ADBIC%3A%3ATraceRS or
via email at bug-devel-dbic-tracers@rt.cpan.org.

=head1 AUTHOR

Norbert Buchmüller <norbi@nix.hu>

=head1 COPYRIGHT

Copyright 2009 Norbert Buchmüller.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
