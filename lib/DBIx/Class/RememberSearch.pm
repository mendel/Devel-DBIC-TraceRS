package DBIx::Class::RememberSearch;

use strict;
use warnings;

use base qw(DBIx::Class);

use Devel::StackTrace;
use Sub::Name;
use Devel::Symdump;
use Scalar::Util;

use DBIx::Class::ResultSet;

DBIx::Class::ResultSet->mk_group_accessors(simple => qw(
  _search_stacktraces
  _search_stacktrace_added_to_exception
  _search_stacktrace_logged
));

sub monkeypatch(*&)
{
  no strict 'refs';
  no warnings 'redefine';

  *{$_[0]} = subname $_[0] => $_[1];
}

my @all_methods =
  grep { /^DBIx::Class::ResultSet::[a-z]/ }
    Devel::Symdump->new("DBIx::Class::ResultSet")->functions;

my @constructor_methods = qw(
  DBIx::Class::ResultSet::new
  DBIx::Class::Schema::resultset
);

my @search_methods =
  grep { /^DBIx::Class::ResultSet::.*(search|related_resultset|slice|page)/ }
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

    $self->_search_stacktraces([
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
foreach my $method (@search_methods) {
  my $orig_method = \&$method;
  monkeypatch $method => sub {
    my $self = shift;

    my $search_stacktrace_logged = $self->_search_stacktrace_logged;
    local $self->{_search_stacktrace_logged} = 1;

    my (@ret, $ret);
    if (wantarray) {
      @ret = $self->$orig_method(@_);
    } elsif (defined wantarray) {
      $ret = $self->$orig_method(@_);
    } else {
      $self->$orig_method(@_);
    }

    $ret->_search_stacktraces([
      @{$self->_search_stacktraces || []},
      $self->_current_search_stacktrace
    ]) if $ret && !$search_stacktrace_logged;

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
    my $search_stacktrace_added_to_exception =
      Scalar::Util::blessed($self) &&
        $self->_search_stacktrace_added_to_exception;
    local $self->{_search_stacktrace_added_to_exception} = 1
      if Scalar::Util::blessed($self);

    my $orig_throw_exception = \&DBIx::Class::Schema::throw_exception;
    monkeypatch local *DBIx::Class::Schema::throw_exception => sub {
      my $schema = shift;

      if ($schema->stacktrace && Scalar::Util::blessed($self) &&
          !$search_stacktrace_added_to_exception) {
        my $stacktraces = "\n" . join("\n---\n",
          map {
            join("\n", map { $_->as_string } $_->frames)
          } @{$self->_search_stacktraces}
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
