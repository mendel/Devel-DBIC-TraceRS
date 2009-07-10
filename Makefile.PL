#!/usr/bin/env perl

use strict;
use warnings;

use inc::Module::Install;

name 'Devel-DBIC-TraceRS';
all_from 'lib/Devel/DBIC/TraceRS.pm';

requires 'Devel::StackTrace' => 0;
requires 'Sub::Name' => 0;
requires 'Devel::Symdump' => 0;
requires 'Scalar::Util' => 0;
requires 'Context::Preserve' => 0;
requires 'Devel::MonkeyPatch::Method' => 0;
requires 'DBIx::Class' => 0;

auto_install;

tests_recursive 't';

WriteAll;
