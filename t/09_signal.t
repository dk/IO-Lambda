#! /usr/bin/perl
# $Id: 09_signal.t,v 1.1 2008/05/07 11:15:42 dk Exp $

use strict;
use warnings;

use Test::More tests => 2;
use Time::HiRes qw(alarm);
use IO::Lambda qw(:all);
use IO::Lambda::Signal qw(:all);

# alarm expires
this lambda {
	alarm(0.5);
	context 'ALRM', 0.1;
	signal {
		alarm(0) unless $_[0];
		$_[0];
	}
};
ok( not(this-> wait), 'signal timed out');

# alarm NOT expires
this lambda {
	alarm(0.1);
	context 'ALRM', 0.5;
	signal {
		alarm(0) unless $_[0];
		$_[0];
	}
};

ok( this-> wait, 'signal caught');
