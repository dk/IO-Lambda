#! /usr/bin/perl
# $Id: 15_thread.t,v 1.7 2008/11/05 15:04:45 dk Exp $

use strict;
use warnings;
use Test::More;
use Config;

alarm(10);

use IO::Lambda qw(:lambda);
use IO::Lambda::Thread qw(threaded);

plan skip_all => $IO::Lambda::Thread::DISABLED if $IO::Lambda::Thread::DISABLED;

plan tests    => 5;

sub sec { select(undef,undef,undef,0.1 * ( $_[0] || 1 )) }

this threaded { 42 };
ok( this-> wait == 42, 'scalar' );

this threaded { (1,2,3) };
ok(( join('', this-> wait) eq '123'), 'list' );

this threaded { sec; 42 };
ok( this-> wait == 42, 'delay' );

this lambda {
	context
		threaded { 1 },
		threaded { 2 },
		threaded { 3 };
	tails { join('', sort @_) }
};
ok( this-> wait eq '123', 'join all' );

my $t;
this lambda {
	context
		0.2,
		threaded { 2 },
		$t = threaded { sec(5); 1 };
	any_tail { join('', sort map { $_-> peek } @_) }
};
ok( this-> wait eq '2', 'join some' );
$t-> join;
this-> clear;
