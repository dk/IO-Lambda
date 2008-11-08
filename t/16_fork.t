#! /usr/bin/perl
# $Id: 16_fork.t,v 1.5 2008/11/08 08:53:14 dk Exp $

use strict;
use warnings;
use Test::More;
use Config;

BEGIN {
	plan skip_all => 'fork is not supported on this platform'
		if $^O =~ /win32/i;
};

alarm(10);

use IO::Lambda qw(:lambda);
use IO::Lambda::Fork qw(forked);

plan tests    => 5;

sub sec { select(undef,undef,undef,0.1 * ( $_[0] || 1 )) }

this forked { 42 };
ok(( join('', this-> wait) eq '42'), 'scalar' );

this forked { (1,5,18) };
ok(( join('', this-> wait) eq '1518'), 'list' );

this forked { sec; 42 };
ok(( join('', this-> wait) eq '42'), 'delay' );

this lambda {
	context
		forked { 1 },
		forked { 2 },
		forked { 3 };
	tails { join('', sort @_) }
};
ok( this-> wait eq '123', 'join all' );

my $t;
this lambda {
	context
		0.2,
		forked { 2 },
		$t = forked { sec(5); 1 };
	any_tail { join('', sort map { $_-> peek } @_) }
};
ok(( join('', this-> wait) eq '2'), 'join some' );

$t-> wait;
