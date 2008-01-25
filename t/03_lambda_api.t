#! /usr/bin/perl
# $Id: 03_lambda_api.t,v 1.6 2008/01/25 13:46:04 dk Exp $

use strict;
use warnings;
use Time::HiRes qw(time);
use Test::More tests => 12;
use IO::Lambda qw(:lambda);

alarm(10);

this lambda {};
this-> wait;
ok( this-> is_stopped, 'lambda api');

this lambda {42};
ok( 42 == this-> wait, 'simple lambda');

this lambda {
	context lambda { 42 };
	tail { 1 + shift };
};
ok( 43 == this-> wait, 'tail lambda');

my $i = 42;
this lambda {
	context lambda {};
	tail { ( $i++ > 44) ? $i : again };
};
ok( 46 == this-> wait, 'restart tail');

this-> reset;
ok( 47 == this-> wait, 'rerun lambda');

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

this lambda {
    context lambda { 1 };
    tail {
        return 3 if 3 == shift;
    	my @frame = this_frame;
        context lambda { 2 };
	tail {
	   context lambda { 3 };
	   again( @frame);
	}
    }
};
ok( '3' eq this-> wait, 'frame restart');

SKIP: {
	skip "select(file) doesn't work on win32", 3 if $^O =~ /win32/i;
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
