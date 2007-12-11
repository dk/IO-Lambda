#!/usr/bin/perl
# $Id: http-redirect.pl,v 1.2 2007/12/11 19:20:05 dk Exp $

use strict;
use HTTP::Request;
use HTTP::Response;
use IO::Lambda qw(:all);
use IO::Socket::INET;

# create chain of event on an existsing lambda object, that when
# finished, will contain the result

sub http_request
{
	my ($q, $req) = @_;
	my $socket = IO::Socket::INET-> new(
		PeerAddr => $req-> uri-> host,
		PeerPort => $req-> uri-> port,
	);
	return $q-> fail("socket error:$@") unless $socket;

	self_context( $q, $socket);
	write {
		print $socket $req-> as_string or return "error:$!";
		my $buf = '';
		read {
			my $n = sysread( $socket, $buf, 1024, length($buf));
			return "error:$!" unless defined $n;
			return HTTP::Response-> parse($buf) unless $n;
			again;
		};
	};
}

# wrap http_request by listening to events from http_request
sub http_redirect_request
{
	my ( $q, $req) = @_;

	my $subq = IO::Lambda-> new;
	http_request( $subq, $req);

	self_context( $q, $subq);
	pipeline {
		my $result = shift;
		return $result unless ref($result);
		return $result if $result-> code !~ /^30/;
		$req-> uri( $result-> header('Location'));
		warn "redirected to ", $req-> uri, "\n";
		push_context;
		http_request( $subq, $req);
		pop_context;
		again;
	};
}

# main call
my $q = IO::Lambda-> new;
my $r = HTTP::Request-> new( GET => 'http://google.com/');
$r-> protocol('HTTP/1.1');
$r-> headers-> header( Host => $r-> uri-> host);
$r-> headers-> header( Connection => 'close');
http_redirect_request( $q, $r);
$q-> tail( sub { 
	my $r = $_[1];
	unless ( ref($r)) {
		print "some error:$r\n";
	} else {
		print "read ", length($r->as_string), " bytes\n";
	}
});
$q-> wait;
