#! /usr/bin/perl
# $Id: 18_poll.t,v 1.2 2009/01/08 15:23:27 dk Exp $
use strict;
use Test::More;
use Fcntl qw(:flock);
use IO::Lambda qw(:all);
use IO::Lambda::Poll qw(poller);

alarm(10);

plan tests => 6;

my $ready = 0;
sub sec { select(undef,undef,undef,0.1 * ( $_[0] || 1 )) }

my $poller = poller { $ready };

this lambda {
	context 0.01, $poller;
	any_tail { scalar @_ }
};
ok( this-> wait == 0, "initial poller is not immediately ready");

$ready = 1;
this lambda {
	context 0.01, $poller;
	any_tail { scalar @_ }
};
ok( this-> wait == 1, "initial poller is immediately ready");

$ready = 0;
$poller-> reset;
$poller-> start;
ok( not(IO::Lambda::Poll::empty), "loop not empty");
$poller-> cancel_all_events;
ok( IO::Lambda::Poll::empty, "loop empty");

$poller-> reset;
this lambda {
	context $poller, timeout => 0.1, frequency => 0.1;
	tail { shift };
};
ok( this-> wait == 0, "poller timed out");

$poller-> reset;
my $polled = -1;
this lambda {
	context $poller, timeout => 1.0, frequency => 0.1;
	tail { $polled = shift };
	context 0.1;
	timeout { $ready = 1 };
};
this-> wait;
ok( $polled == 1, "poller not timed out");


