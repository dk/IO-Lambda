#! /usr/bin/perl
# $Id: 09_signal.t,v 1.4 2008/05/09 19:02:51 dk Exp $

use strict;
use warnings;

use Time::HiRes;
use Test::More tests => 2;
use IO::Lambda qw(:all);
use IO::Lambda::Signal qw(:all);

# alarm expires
this lambda {
	alarm(1.0);
	context 'ALRM', 0.1;
	signal {
		alarm(0) unless $_[0];
		$_[0];
	}
};
ok( not(this-> wait), 'signal timed out');

# alarm NOT expires
SKIP: {
	skip "SIGALRM doesn't break select() on win32", 1 if $^O =~ /win32/i;
	this lambda {
		Time::HiRes::alarm(0.5);
		context 'ALRM', 1.0;
		signal {
			alarm(0) unless $_[0];
			$_[0];
		}
	};
	ok( this-> wait, 'signal caught');
}

