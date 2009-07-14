#!/usr/bin/env perl -T

use strict;
use warnings;

use lib qw(t/lib);

use Test::Most;
use TestHelper;

# Ensure a recent version of Test::Pod::Coverage
my $min_tpc = 1.08;
eval "use Test::Pod::Coverage $min_tpc";
plan skip_all => "Test::Pod::Coverage $min_tpc required for testing POD coverage"
    if $@;

# Test::Pod::Coverage doesn't require a minimum Pod::Coverage version,
# but older versions don't recognize some common documentation styles
my $min_pc = 0.18;
eval "use Pod::Coverage $min_pc";
plan skip_all => "Pod::Coverage $min_pc required for testing POD coverage"
    if $@;

plan skip_all => 'set TEST_POD to enable this test'
  unless is_author_running_test;

all_pod_coverage_ok();
