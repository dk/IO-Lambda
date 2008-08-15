#! /usr/bin/perl
# $Id: 13_synthetic.t,v 1.3 2008/08/15 14:51:00 dk Exp $

use strict;
use warnings;
use Test::More tests => 2;
use IO::Lambda qw(:all);

# dummy factory

my $a0 = 0;
my $b0 = 3;
sub f
{
	my @b = @_;
	return lambda {
		my @c = @_;
		return "$a0/@b/@c";
	};
}

# test synthetic predicates
sub new_predicate(&)
{ 
	f($a0++)-> call($b0++)-> predicate( shift, \&new_predicate) 
}

my $a2 = 0;
this lambda {
	context 'a';
	new_predicate { join('', @_, $a2++, context) }
};

ok(this-> wait eq '1/0/30a', 'synthetic predicate 1');
this-> reset;
ok(this-> wait eq '2/1/41a', 'synthetic predicate 2');
