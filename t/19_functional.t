#! /usr/bin/perl
# $Id: 19_functional.t,v 1.1 2008/12/18 20:32:14 dk Exp $

use strict;
use warnings;
use Test::More;
use IO::Lambda qw(:lambda :func);

plan tests => 5;

ok('12345' eq join('', seq-> wait( map { my $k = $_; lambda { $k } } 1..5 )), 'seq');

my ( $curr, $max) = (0,0);
sub xl
{
	my $id = shift;
	lambda {
		context 0.1;
		$curr++;
	sleep {
		$max = $curr if $max < $curr;
		$curr--;
		return $id;
	}}
}

my @b = par(3)-> wait( map { xl( int($_ / 3)) } 0..8);
ok(
	('000111222' eq join('',@b) and $max == 3),
	'par'
);

ok( '23456' eq join('', mapcar( lambda { 1 + shift   })-> wait(1..5)), 'mapcar');
ok( '135'   eq join('', filter( lambda { shift() % 2 })-> wait(1..5)), 'filter');

ok( 10 == fold( lambda { $_[0] + $_[1] })-> wait(1..4), 'fold');
