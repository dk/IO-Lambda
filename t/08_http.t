#! /usr/bin/perl
# $Id: 08_http.t,v 1.2 2008/05/09 19:11:31 dk Exp $

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
	my $r = http_lambda('www.google.com')-> wait;
	ref($r) ? ok(1,"http_get(google)") : ok(0,"http_get(google):$r");

	# many
	lambda {
		context map { http_lambda('www.google.com') } 1..3;
		tails { ok(( 3 == grep { ref($_) } @_), 'parallel resolve') }
	}-> wait;
}
