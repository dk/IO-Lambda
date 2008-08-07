#! /usr/bin/perl
# $Id: 07_dns.t,v 1.2 2008/08/07 19:36:15 dk Exp $

use strict;
use warnings;

use Test::More tests => 3;
use IO::Lambda qw(:all);
use IO::Lambda::DNS qw(:all);

SKIP: {
	skip "online tests disabled", 3 unless -e 't/online.enabled';

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
}
