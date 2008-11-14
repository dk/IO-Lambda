# $Id: 17_flock.t,v 1.1 2008/11/14 15:06:24 dk Exp $
use strict;
use Test::More;
use Fcntl qw(:flock);
use IO::Lambda qw(:all);
use IO::Lambda::Flock qw(flock);
use IO::Lambda::Fork qw(forked);

alarm(10);

plan tests => 3;

my $f = forked {
	open F, ">test.lock";
	CORE::flock( \*F, LOCK_EX);
	CORE::sleep(1);
	close F;
};
$f-> start;

open F, ">test.lock";
my $l = CORE::flock(\*F, LOCK_EX|LOCK_NB);
ok( not($l), "initial lock is not obtained");

my $got_it = 2;
lambda {
	context \*F, 0.2;
	flock { $got_it = ( shift() ? 1 : 0) }
}-> wait;
ok( $got_it == 0, "timeout ok ($got_it)");

lambda {
	context \*F, 2.0;
	flock { $got_it = ( shift() ? 1 : 0) }
}-> wait;
ok( $got_it == 1, "lock ok ($got_it)");

$f-> wait;

unlink 'test.lock';
