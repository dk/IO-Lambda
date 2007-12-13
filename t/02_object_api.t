#! /usr/bin/perl
# $Id: 02_object_api.t,v 1.1 2007/12/13 23:00:08 dk Exp $

use strict;
use warnings;
use Test::More tests => 15;
use IO::Lambda qw(:all :constants);

# empty lambda
my $l = IO::Lambda-> new;
ok( $l, 'create IO::Lambda');
ok( not($l-> stopped), 'initial lambda is not stopped');

ok( $l-> step, 'step reports data is available');
ok( $l-> stopped, 'empty lambda is stopped after first step');

$l-> reset;
ok( not($l-> stopped), 'reset lambda is not stopped');

$l-> terminate('moo', 42);
ok( $l-> stopped, 'terminated lambda is stopped');

ok( 2 == @{$l-> peek} ,     'passed data ok');
ok('moo' eq $l-> peek->[0], 'retrieved data ok');

# lambda with initial callback
$l = IO::Lambda-> new( sub { 1, 42 } );
$l-> wait;
my @x = $l-> peek;
ok(( 2 == @x and $x[1] == 42), 'single callback');

# two lambdas, one waiting for another
my $m = IO::Lambda-> new( sub { 10 } );
$l-> reset;
$l-> watch_lambda( $m, sub { @x = @_ });
$l-> wait;
ok(( 2 == @x and $x[1] == 10), 'watch_lambda');

# timer
$m-> reset;
$m-> watch_timer( time, sub { @x = 'time' });
$m-> wait;
ok(( 1 == @x and $x[0] eq 'time'), 'watch_timer');

$m-> reset;
$m-> watch_timer( time, sub { 'time' });
$l-> reset;
$l-> watch_lambda( $m, sub { @x = @_ });
$l-> wait;
ok(( 2 == @x and $x[1] eq 'time'), 'propagate timer');

# file
SKIP: {
	skip "cannot open $0:$!", 3 unless open FH, '<', $0;

	$m-> reset;
	$m-> watch_io( IO_READ, \*FH, time, sub { @x = @_ });
	$m-> wait;
	ok(( 2 == @x and $x[1] == IO_READ), 'io read');
	
	$m-> reset;
	$m-> watch_io( IO_READ|IO_EXCEPTION, \*FH, time, sub { @x = @_ });
	$m-> wait;
	ok(( 2 == @x and $x[1] == IO_READ), 'io read/exception');
	
	$l-> reset;
	$m-> reset;
	$m-> watch_io( IO_READ, \*FH, time, sub { 42 });
	$l-> watch_lambda( $m, sub { @x = @_ });
	$l-> wait;
	ok(( 2 == @x and $x[1] == 42), 'io propagate');

	close FH;
}
