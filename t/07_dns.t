#! /usr/bin/perl
# $Id: 07_dns.t,v 1.1 2008/05/06 20:41:33 dk Exp $

use strict;
use warnings;

use Test::More tests => 3;
use IO::Lambda qw(:all);
use IO::Lambda::DNS qw(:all);

SKIP: {
	skip "online tests disabled", 3 unless -e 't/online.enabled';

	# simple
	ok( dns_lambda('www.google.com')-> wait =~ /^\d/, "resolve google(a)");

	# packet-wise
	ok( ref(dns_lambda('www.google.com', 'mx')-> wait), "resolve google(mx)");

	# resolve many
	lambda {
		context map { dns_lambda('www.google.com') } 1..3;
		tails { ok(( 3 == grep { /^\d/ } @_), 'parallel resolve') }
	}-> wait;
}
