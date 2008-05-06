#! /usr/bin/perl
# $Id: 08_http.t,v 1.1 2008/05/06 20:41:33 dk Exp $

use strict;
use warnings;

use Test::More tests => 2;
use HTTP::Request;
use IO::Lambda qw(:all);
use IO::Lambda::HTTP;

sub http_lambda
{
	IO::Lambda::HTTP-> new(
		HTTP::Request-> new( 
			GET => "http://$_[0]/"
		))
}

SKIP: {
	skip "online tests disabled", 2 unless -e 't/online.enabled';

	# single
	ok( ref(http_lambda('www.google.com')-> wait), "http_get(google)");

	# many
	lambda {
		context map { http_lambda('www.google.com') } 1..3;
		tails { ok(( 3 == grep { ref($_) } @_), 'parallel resolve') }
	}-> wait;
}
