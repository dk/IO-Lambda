#! /usr/bin/perl
# $Id: 05_condvar.t,v 1.2 2007/12/15 23:03:16 dk Exp $

use strict;
use warnings;
use Time::HiRes qw(time);
use Test::More tests => 5;
use IO::Lambda qw(:all);

package PseudoLoop;

sub yield  {}
sub remove { $_[0]-> {q} = $_[1] }
sub new    { bless {}, shift  }

package main;

my $q    = IO::Lambda-> new;
my $cond = $q-> bind;
my $q2   = lambda {
	context time + 0.1;
	ok( not( $q-> is_stopped), 'bind');
	sleep { $q-> resolve($cond) }
};
$q-> wait;
ok( $q-> is_stopped, 'resolve');

my $loop = PseudoLoop-> new;

IO::Lambda::add_loop( $loop );

$q-> reset;
$q-> bind;
$q-> reset;
ok(( defined($loop-> {q}) and ( $loop->{q} eq $q)), 'custom event loop');
ok( $q-> is_passive, 'reset with custom loop');

IO::Lambda::remove_loop( $loop);
$q-> bind;
$q-> reset;
ok( $q-> is_passive, 'reset without custom loop');
