# $Id: 17_flock.t,v 1.2 2008/11/14 20:13:56 dk Exp $
use strict;
use Test::More;
use Fcntl qw(:flock);
use IO::Lambda qw(:all);
use IO::Lambda::Flock qw(flock);

alarm(10);

plan tests => 3;

open G, ">test.lock";
CORE::flock( \*G, LOCK_EX);

open F, ">test.lock";
my $l = CORE::flock(\*F, LOCK_EX|LOCK_NB);
ok( not($l), "initial lock is not obtained");

my $got_it = 2;
lambda {
	context \*F, timeout => 0.2, frequency => 0.2;
	flock { $got_it = ( shift() ? 1 : 0) }
}-> wait;
ok( $got_it == 0, "timeout ok ($got_it)");

$got_it = 2;
lambda {
	context \*F, timeout => 2.0, frequency => 0.2;
	flock { $got_it = ( shift() ? 1 : 0) };
	context 0.5;
	sleep { close G };
}-> wait;
ok( $got_it == 1, "lock ok ($got_it)");

unlink 'test.lock';
