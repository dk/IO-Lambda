#! /usr/bin/perl
# $Id: 03_lambda_api.t,v 1.1 2007/12/13 23:00:08 dk Exp $

use strict;
use warnings;
use Test::More tests => 12;
use IO::Lambda qw(:all);

this lambda {};
this-> wait;
ok( this-> stopped, 'lambda api');

this lambda {42};
ok( 42 == this-> wait, 'simple lambda');

this lambda {
	context lambda { 42 };
	tail { 1 + shift };
};
ok( 43 == this-> wait, 'tail lambda');

my $i = 42;
my $r;
this lambda {
	$r = shift;
	( $i++ > 44) ? $i : again;
};
ok(( 46 == this-> wait(2) && $r == 2), 'restart lambda');

this-> reset;
ok(( 47 == this-> wait(3) && $r == 3), 'rerun lambda');

$i = 42;
this lambda {
	context lambda {};
	tail { ( $i++ > 44) ? $i : again };
};
ok( 46 == this-> wait, 'restart tail');

this lambda {
	context time + 0.01;
	sleep { 'moo' };
};
ok( 'moo' eq this-> wait, 'sleep');

this lambda {
	context lambda {};
	tail {
		context time + 0.01;
		sleep { 'moo' };
	};
};
ok( 'moo' eq this-> wait, 'tail sleep');

$i = 2;
this lambda {
	context time + 0.01;
	sleep { $i-- ? again : 'moo' };
};
ok(( 'moo' eq this-> wait && $i == -1), 'restart sleep');

SKIP: {
	skip "cannot open $0:$!", 3 unless open FH, '<', $0;

this lambda {
	context \*FH;
	read { 'moo' };
};
ok( 'moo' eq this-> wait, 'read');


this lambda {
	context lambda {};
	tail {
		context \*FH;
		read { 'moo' };
	};
};
ok( 'moo' eq this-> wait, 'tail read');

$i = 2;
this lambda {
	context \*FH;
	read { $i-- ? again : 'moo' };
};
ok(( 'moo' eq this-> wait && $i == -1), 'restart read');

}
