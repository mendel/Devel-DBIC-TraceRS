package TestHelper;

use strict;
use warnings;

=head1 NAME

TestHelper - Various distribution-specific test helpers.

=head1 SYNOPSIS

  use TestHelper;

=head1 DESCRIPTION

Various utilities common to all testcases of this distribution.

=cut

use base qw(Exporter);
our @EXPORT = qw(
  &is_author_running_test
);

use FindBin;
use File::Spec;

=head2 is_author_running_test()

Returns true iff the author runs the test.

=cut

sub is_author_running_test()
{
  return $ENV{TEST_POD}
    || $ENV{TEST_AUTHOR}
    || -e File::Spec->catfile($FindBin::Bin, File::Spec->updir, 'inc', '.author');
}

1;
