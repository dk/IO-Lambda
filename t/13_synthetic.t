#! /usr/bin/perl
# $Id: 13_synthetic.t,v 1.1 2008/08/07 14:32:58 dk Exp $

use strict;
use warnings;
use Test::More tests => 6;
use IO::Lambda qw(:all);

# dummy factory and predicate

my $a0 = 0;
sub factory
{
	$a0++;
	my @b = @_;
	return lambda {
		my @c = @_;
		return "$a0/@b/@c";
	};
}

my $a1 = 0;
sub predicate(&)
{
	my @ctx = context;
	this-> watch_lambda( lambda {
		this( shift, @ctx);
		$a1++;
		return "$a1/@ctx";
	}, shift);
}

# test synthetic predicates
sub new_predicate(&); 
*new_predicate = IO::Lambda-> to_predicate( \&factory, 'f', 2);

my $a2 = 0;
this lambda {
	context 1,2,3,4,5;
	new_predicate {
		$a2++;
		return "$_[0]/$a2";
	}
};
ok(this-> wait eq '1/1 2/3 4 5/1', 'synthetic predicate 1');
this-> reset;
ok(this-> wait eq '2/1 2/3 4 5/2', 'synthetic predicate 2');

sub predicate0(&); 
*predicate0 = IO::Lambda-> to_predicate( \&factory, 'f', 0);

this lambda {
	context 1,2,3,4,5;
	predicate0 {
		$a2++;
		return "$_[0]/$a2";
	}
};
ok(this-> wait eq '3//1 2 3 4 5/3', 'synthetic predicate 3');

sub predicate1(&); 
*predicate1 = IO::Lambda-> to_predicate( \&factory, 'f', -1);

this lambda {
	context 1,2,3,4,5;
	predicate1 {
		$a2++;
		return "$_[0]/$a2";
	}
};
ok(this-> wait eq '4/1 2 3 4 5//4', 'synthetic predicate 4');

# test synthetic factories
*fac = IO::Lambda-> to_factory( \&predicate);
ok( fac()-> wait(2) eq '1/2', 'synthetic factory 1');
ok( fac()-> wait(2) eq '2/2', 'synthetic factory 2');
