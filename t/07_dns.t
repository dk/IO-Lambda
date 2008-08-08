#! /usr/bin/perl
# $Id: 07_dns.t,v 1.3 2008/08/08 07:37:50 dk Exp $

use strict;
use warnings;

use Test::More;
use IO::Lambda qw(:all);
use IO::Lambda::DNS qw(:all);

plan skip_all => "online tests disabled" unless -e 't/online.enabled';
plan tests    => 3;

# simple
ok(
	IO::Lambda::DNS-> new('www.google.com')-> wait =~ /^\d/,
	"resolve google(a)"
);

# packet-wise
ok(
	ref(IO::Lambda::DNS-> new('www.google.com', 'mx')-> wait),
	"resolve google(mx)"
);

# resolve many
lambda {
	context map { 
		IO::Lambda::DNS-> new('www.google.com')
	} 1..3;
	tails { ok(( 3 == grep { /^\d/ } @_), 'parallel resolve') }
}-> wait;
