#!perl -T

use Test::Most tests => 1;

BEGIN {
	use_ok( 'Devel::DBIC::TraceRS' );
}

diag( "Testing Devel::DBIC::TraceRS $Devel::DBIC::TraceRS::VERSION, Perl $], $^X" );
