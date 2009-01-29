#! /usr/bin/perl
# $Id: 20_mutex.t,v 1.2 2009/01/29 16:29:15 dk Exp $

alarm(10);

use strict;
use warnings;
use Test::More;
use IO::Lambda qw(:lambda);
use IO::Lambda::Mutex;

plan tests => 12;

# basic stuff
my $mutex = IO::Lambda::Mutex-> new;
ok( $mutex-> is_free, 'new mutex is free');

$mutex-> take;
ok( $mutex-> is_taken, 'new mutex is taken');
$mutex-> release;
ok( $mutex-> is_free, 'new mutex is free again');

# wait for mutex that shall be available immediately
my $waiter = $mutex-> waiter;
my $error = $waiter-> wait;
ok( not(defined $error), 'immediate wait ok');
ok( $mutex-> is_taken, 'awaited mutex is taken');
$mutex-> release;
ok( $mutex-> is_free, 'awaited mutex is free again');

# wait for blocked mutex
$mutex-> take;
$waiter = $mutex-> waiter;
my $flag = 0;
my $sleeper = lambda {
	context 0.2;
	timeout {
		$flag++;
		$mutex-> release;
	}
};
$sleeper-> start;
$error = $waiter-> wait;
ok( not(defined $error) && $flag == 1, 'unconditional wait ok');
ok( $mutex-> is_taken, 'awaited mutex is taken');

# wait for blocked mutex with a timeout
$waiter = $mutex-> waiter(0.001);
$flag = 0;
$sleeper-> reset;
$sleeper-> start;
$error = $waiter-> wait;
ok( defined($error) && $error eq 'timeout', 'conditional wait ok');
ok( $mutex-> is_free, 'awaited mutex is free');

# deadlock prevention
$mutex-> take;
$waiter = $mutex-> waiter;
$waiter-> terminate;
$mutex-> release;
ok( $mutex-> is_free, 'deadlock prevention 1');

$mutex-> take;
$waiter = $mutex-> waiter;
$mutex-> remove($waiter);
ok( $mutex-> is_free, 'deadlock prevention 2');

