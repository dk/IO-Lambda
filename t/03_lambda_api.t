#! /usr/bin/perl
# $Id: 03_lambda_api.t,v 1.13 2008/12/30 20:16:12 dk Exp $

use strict;
use warnings;
use Test::More tests => 15;
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
	my $l = lambda {}; 
	context $l;
	tail { ( $i++ > 44) ? $i : ( $l-> reset, again ) };
};
ok( 46 == this-> wait, 'restart tail');

this-> reset;
ok( 47 == this-> wait, 'rerun lambda');

this lambda {
	context 0.01;
	sleep { 'moo' };
};
ok( 'moo' eq this-> wait, 'sleep');

this lambda {
	context lambda {};
	tail {
		context 0.01;
		sleep { 'moo' };
	};
};
ok( 'moo' eq this-> wait, 'tail sleep');

$i = 2;
this lambda {
	context 0.01;
	sleep { $i-- ? again : 'moo' };
};
ok(( 'moo' eq this-> wait && $i == -1), 'restart sleep');

this lambda {
    context lambda { 1 };
    tail {
        return 3 if 3 == shift;
    	my @frame = restartable;
        context lambda { 2 };
	tail {
	   context lambda { 3 };
	   again( @frame);
	}
    }
};
ok( '3' eq this-> wait, 'frame restart');

this lambda {
	context 
		lambda { 1 }, 
		lambda { context 0.1; sleep { 2 }},
		lambda { 3 };
	tailo { join '', @_ }
};
ok( '123' eq this-> wait, 'tailo');

this lambda {
	context 
		0.1, 
		lambda { 1 }, 
		lambda { context 1.0; sleep { 2 }},
		lambda { 3 };
	any_tail { join '', sort map { $_-> peek } @_ };
};
ok( '13' eq this-> wait, 'any_tail');

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

ok( 0 == scalar(@_ = lambda { tails { @_ } }-> wait) , 'empty tails');
