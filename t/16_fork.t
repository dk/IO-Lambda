#! /usr/bin/perl
# $Id: 16_fork.t,v 1.1 2008/11/05 16:06:06 dk Exp $

use strict;
use warnings;
use Test::More;
use Config;

BEGIN {
	plan skip_all => 'Fork is not supported'
		if $^O =~ /win32/i;
};

use IO::Lambda qw(:lambda);
use IO::Lambda::Fork qw(forked);

plan tests    => 5;

sub sec { select(undef,undef,undef,0.1 * ( $_[0] || 1 )) }

this forked { 42 };
ok(( join('', this-> wait) eq '042'), 'scalar' );

this forked { (1,5,18) };
ok(( join('', this-> wait) eq '018'), 'list' );

this forked { sec; 42 };
ok(( join('', this-> wait) eq '042'), 'delay' );

this lambda {
	context
		forked { 1 },
		forked { 2 },
		forked { 3 };
	tails { join('', sort @_) }
};
ok( this-> wait eq '000123', 'join all' );

my $t;
this lambda {
	context
		0.2,
		forked { 2 },
		$t = forked { sec(5); 1 };
	any_tail { join('', sort map { $_-> peek } @_) }
};
ok(( join('', this-> wait) eq '02'), 'delay' );
$t-> join;
this-> clear;
