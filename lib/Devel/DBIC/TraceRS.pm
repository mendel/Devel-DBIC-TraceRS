package Devel::DBIC::TraceRS;

#FIXME tests
# * $schema->resultset('...')
# * $result_source->resultset
# * new()
# * $rs->search(...)
# * $rs->search_rs(...)
# * $rs->search_literal(...)
# * $rs->search_like(...)
# * $rs->search_related(...)
# * $rs->search_related_rs(...)
# * $rs->related_resultset(...)
# * $rs-><one_to_many-accessor>
# * $rs-><one_to_many-accessor>_rs
# * $rs-><many_to_many-accessor>
# * $rs-><many_to_many-accessor>_rs
# * $rs->slice(...)
# * $rs->page(...)

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

When you pass L<DBIx::Class::ResultSet> instances between different parts of
your code, the actual place where it executes the SQL query can be very far
from the place where the resultset was built up. And if you make a mistake
while building up the resultset object (eg. a typo in a search condition or a
missing join), the error is not discovered until DBIC runs the generated SQL.
Then, sometimes, it's hard to tell at first glance where the actual error is.
Well, a tinge of action at a distance.

This is where this module comes to the rescue.

If you C<use> this module, every L<DBIx::Class::ResultSet> instance remembers
all calls that led to its current state (all relevant calls in the process of
'building up' the resultset). When any method called on the resultset throws an
exception, and C<DBIx::Class::Schema/stacktrace> is enabled, the list of
stacktraces of those build-up calls are appended to the exception message. See
the L<EXAMPLES>.

=head1 VERSION

=cut

our $VERSION = 0.01;

use Devel::StackTrace;
use Devel::Symdump;
use Scalar::Util qw(blessed);
use Context::Preserve;
use Devel::MonkeyPatch::Sub qw(wrap_sub);

# make sure they are loaded so that we can monkey-patch them
use DBIx::Class::Schema;
use DBIx::Class::ResultSet;
use DBIx::Class::ResultSource;

DBIx::Class::ResultSet->mk_group_accessors(simple => qw(
  _tracers_stacktrace_captured
  _tracers_stacktraces
  _tracers_stacktrace_appended_to_msg
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

=head1 METHODS

=cut

# wrap all traced methods so we can capture the stacktrace
foreach my $method (@traced_resultset_methods, @other_traced_methods) {
  wrap_sub $method => sub {
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
          Devel::StackTrace->new(
            ignore_class => [
              __PACKAGE__, qw(Context::Preserve Devel::MonkeyPatch::Sub)
            ],
            no_refs => 1,
          ),
        ]) if blessed($ret) && $ret->isa('DBIx::Class::ResultSet');
      };
  };
}

# wrap all methods to rewrite the message of the exceptions thrown from them
foreach my $method (@all_resultset_methods) {
  wrap_sub $method => sub {
    my $self = shift;

    if (blessed($self) && !$self->_tracers_stacktrace_appended_to_msg) {
      # do not append the stacktrace to the message more than once
      local $self->{_tracers_stacktrace_appended_to_msg} = 1;

      local *DBIx::Class::Schema::throw_exception =
        \&DBIx::Class::Schema::throw_exception;
      wrap_sub *DBIx::Class::Schema::throw_exception => sub {
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

=head1 EXAMPLES

=head2 The demo code

  #!/usr/bin/env perl 

  {
    package Foo;

    use strict;
    use warnings;

    sub new
    {
      my ($class, $rs) = (shift, @_);

      return bless { rs => $_[0] }, $class;
    }

    sub search_for
    {
      my ($self, $id) = (shift, @_);

      return $self->{rs}->search({ aartistid => $id });
    }
  }

  use strict;
  use warnings;

  use MyDb::Schema;

  my $schema = MyDb::Schema->connect("dbi:SQLite:tmp/my.db");
  $schema->stacktrace(1);

  my $foo = Foo->new($schema->resultset("Artist"));

  my $rs = $foo->search_for(1)->slice(0, 5);

  while (my $artist = $rs->next) {
    # ...
  }

=head2 The stack trace without Devel::DBIC::TraceRS

  DBI Exception: DBD::SQLite::db prepare_cached failed: no such column: aartistid [for Statement "SELECT me.artistid, me.name FROM artist me WHERE ( aartistid = ? ) LIMIT 6"] at /usr/local/share/perl/5.10.0/DBIx/Class/Schema.pm line 1010
    DBIx::Class::Schema::throw_exception('MyDb::Schema=HASH(0x817f760)', 'DBI Exception: DBD::SQLite::db prepare_cached failed: no such...') called at /usr/local/share/perl/5.10.0/DBIx/Class/Storage.pm line 122
    ... (removed uninteresting lines)
    DBIx::Class::ResultSet::next('DBIx::Class::ResultSet=HASH(0x862ff30)') called at demo.pl line 35

=head2 The stack trace using Devel::DBIC::TraceRS


  DBI Exception: DBD::SQLite::db prepare_cached failed: no such column: aartistid [for Statement "SELECT me.artistid, me.name FROM artist me WHERE ( aartistid = ? ) LIMIT 6"]
  [ +- search calls ----
    | DBIx::Class::Schema::resultset('MyDb::Schema=HASH(0x817f760)', 'Artist') called at demo.pl line 31
    | ---
    | DBIx::Class::ResultSet::search('DBIx::Class::ResultSet=HASH(0x8652640)', 'HASH(0x8545600)') called at demo.pl line 20
    | Foo::search_for('Foo=HASH(0x8676e28)', 1) called at demo.pl line 33
    | ---
    | DBIx::Class::ResultSet::slice('DBIx::Class::ResultSet=HASH(0x867d5a0)', 0, 5) called at demo.pl line 33
    +------------------- ] at /usr/local/share/perl/5.10.0/DBIx/Class/Schema.pm line 1010
    DBIx::Class::Schema::throw_exception('MyDb::Schema=HASH(0x817f760)', 'DBI Exception: DBD::SQLite::db prepare_cached failed: no such...') called at lib/Devel/DBIC/TraceRS.pm line 148
    ... (removed uninteresting lines)
    DBIx::Class::ResultSet::next('DBIx::Class::ResultSet=HASH(0x86808f8)') called at demo.pl line 35


=head1 BUGS, CAVEATS AND NOTES

=head2 Performance and stability

It monkey-patches all methods of L<DBIx::Class::ResultSet> and some methods of
other L<DBIx::Class> parts. Consequently it hurts performance and may make the
code unstable.

This module is only meant to be used while you're developing the code. B<Do not
use this module in production!>

=head2 Future DBIx::Class versions

Since this module performs its job by wrapping methods and intruding into
internals of L<DBIx::Class>, future L<DBIx::Class> releases may break it.

=head1 SEE ALSO

L<DBIx::Class>, L<Devel::StackTrace>, L<Devel::MonkeyPatch::Sub>

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
