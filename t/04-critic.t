use strict;
use warnings;

use FindBin;
use File::Spec;
use Test::Most;

if (!$ENV{TEST_AUTHOR} && !-e File::Spec->catfile($FindBin::Bin, File::Spec->updir, 'inc', '.author')) {
  plan skip_all => 'Critic test only for developers.';
} else {
  eval { require Test::Perl::Critic };
  if ( $@ ) {
    plan tests => 1;
    fail( 'You must install Test::Perl::Critic to run 04critic.t' );
    exit;
  }
}

my $rcfile = File::Spec->catfile( 't', '04-critic.rc' );
Test::Perl::Critic->import( -profile => $rcfile );
all_critic_ok();
