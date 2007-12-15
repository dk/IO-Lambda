#! /usr/bin/perl
# $Id: 05_condvar.t,v 1.1 2007/12/15 14:26:38 dk Exp $

use strict;
use warnings;
use Time::HiRes qw(time);
use Test::More tests => 5;
use IO::Lambda qw(:all);

my $q    = IO::Lambda-> new;
my $cond = $q-> bind;
my $q2   = lambda {
	context time + 0.1;
	ok( not( $q-> is_stopped), 'bind');
	sleep { $q-> resolve($cond) }
};
$q-> wait;
ok( $q-> is_stopped, 'resolve');

sub unsubscribe { ok( $_[0] eq $q, 'unsubscribe') }

IO::Lambda::add_unsubscriber( \&unsubscribe);

$q-> reset;
$q-> bind;
$q-> reset;
ok( $q-> is_passive, 'reset with unsibscriber');

IO::Lambda::remove_unsubscriber( \&unsubscribe);
$q-> bind;
$q-> reset;
ok( $q-> is_passive, 'reset without unsubscriber');
