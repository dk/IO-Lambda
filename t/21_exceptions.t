#! /usr/bin/perl
# $Id: 21_exceptions.t,v 1.3 2009/02/14 09:45:48 dk Exp $

alarm(10);

use strict;
use warnings;
use Test::More;
use IO::Lambda qw(:lambda);

plan tests => 25;

# just throw
sub throw
{
	lambda { this-> throw('throw') }
}

# exceptions pass through
sub bypass
{
	my $listen = shift;
	lambda {
		context $listen;
		tail { 'pass' };
	}
}

# just a fork
sub forks
{
	my @t = @_;
	lambda {
		context @t;
		tails { @_ }
	}
}

# catch expection, do not propagate further
sub caught
{
	my $listen = shift;
	lambda {
		context $listen;
		catch { 'caught', @_ }
		tail  { 'passed', @_ }
	}
}

# bypass expection but do something
sub fin
{
	my $listen = shift;
	lambda {
		context $listen;
		finally { shift; 'finally', @_ }
		tail    { @_ }
	}
}

# catch exception and do not propagate
sub finc
{
	my $listen = shift;
	lambda {
		context $listen;
		finally { shift; shift() . 'finally', @_ }
		catch   { shift; 'caught+', @_ }
		tail    { shift; 'passed+', @_ }
	}
}

# normal exceptions
ok( throw-> wait eq 'throw', 'throw');
ok( bypass(lambda{})-> wait eq 'pass', 'pass');
ok( bypass(throw)-> wait eq 'throw', 'bypass/1');
ok( fin(throw)-> wait eq 'finally', 'finally');
ok( finc(throw)-> wait eq 'caught+finally', 'catch+finally');
ok( forks(throw)-> wait eq 'throw', 'bypass/*');
ok( caught(throw)-> wait eq 'caught', 'catch');
ok( caught(fin(throw))-> wait eq 'caught', 'finally bypasses ok');
ok( caught(finc(throw))-> wait eq 'passed', 'catch+finally catches ok');
ok( fin(caught(throw))-> wait eq 'finally', 'finally/catch');
ok( finc(caught(throw))-> wait eq 'passed+finally', 'catch+finally/catch');
ok( caught(bypass(throw))-> wait eq 'caught', 'catch/bypass');
ok( fin(caught(bypass(throw)))-> wait eq 'finally', 'finally/catch/bypass');
ok( finc(caught(bypass(throw)))-> wait eq 'passed+finally', 'catch+finally/catch/bypass');
ok( caught(caught(throw))-> wait eq 'passed', 'catch/catch');

# SIGTHROW
my $sig = 0;
IO::Lambda-> sigthrow( sub { $sig++ });
throw-> wait;
ok( $sig, 'sigthrow on');

$sig = 0;
IO::Lambda-> sigthrow(undef);
ok( 0 == $sig, 'sigthrow off');

IO::Lambda::sigthrow( sub { $sig++ });
throw-> wait;
ok( $sig, 'sigthrow on');

$sig = 0;
IO::Lambda::sigthrow(undef);
ok( 0 == $sig, 'sigthrow off');

# stack
sub stack
{
	lambda {
		context 0.001;
	# make sure that lambdas wait for each other before throw is called
	timeout {
		this-> throw( this-> backtrace )
	}}
}

my $s = stack-> wait;
ok((1 == @$s and 1 == @{$s->[0]}), 'stack 1/1');

$s = bypass( stack )-> wait;
ok((1 == @$s and 2 == @{$s->[0]}), 'stack 1/2');

$s = bypass( bypass( stack ))-> wait;
ok((1 == @$s and 3 == @{$s->[0]}), 'stack 1/3');

my $x = stack;
$s = forks($x, $x)-> wait;
ok((2 == @$s and 2 == @{$s->[0]} and 2 == @{$s->[1]}), 'stack 2/2/2');

$x = stack;
$s = forks(bypass($x), bypass($x))-> wait;
ok((2 == @$s and 3 == @{$s->[0]} and 3 == @{$s->[1]}), 'stack 2/3/3');

$x = stack;
$x = bypass($x);
$s = forks(bypass($x), bypass($x))-> wait;
ok((2 == @$s and 4 == @{$s->[0]} and 4 == @{$s->[1]}), 'stack 2/4/4');

