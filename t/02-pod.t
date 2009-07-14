#!/usr/bin/env perl -T

use strict;
use warnings;

use lib qw(t/lib);

use Test::Most;
use TestHelper;

# Ensure a recent version of Test::Pod
my $min_tp = 1.22;
eval "use Test::Pod $min_tp";
plan skip_all => "Test::Pod $min_tp required for testing POD" if $@;

plan skip_all => 'set TEST_POD to enable this test'
  unless is_author_running_test;

all_pod_files_ok();
