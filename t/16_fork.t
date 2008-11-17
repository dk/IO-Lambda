#! /usr/bin/perl
# $Id: 16_fork.t,v 1.7 2008/11/17 14:27:22 dk Exp $

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
my $ret = join('', this-> wait);
ok( $ret eq '123', "join all ($ret)" );

my $t;
this lambda {
	context
		0.8,
		forked { 2 },
		$t = forked { sec(10); 1 };
	any_tail { join('', sort map { $_-> peek } @_) }
};
$ret = join('', this-> wait);
ok(( $ret eq '2'), "join some($ret)");

$t-> wait;
