#! /usr/bin/perl
# $Id: 08_http.t,v 1.3 2008/08/08 07:37:50 dk Exp $

use strict;
use warnings;

use Test::More;
use HTTP::Request;
use IO::Lambda qw(:all);
use IO::Lambda::HTTP::Client;
use IO::Lambda::HTTP::Server;
use LWP::ConnCache;

plan skip_all => "online tests disabled" unless -e 't/online.enabled';

my %opt;

sub http_lambda
{
	IO::Lambda::HTTP::Client-> new(
		HTTP::Request-> new( 
			GET => "http://$_[0]/"
		), %opt)
}

# own
my $port   = $ENV{TESTPORT} || 29876;
my $num = 0;
my ($server, $error) = http_server {
	$num++;
	if ( $num == 1 ) {
		return HTTP::Response->new(200, 'OK', ['Content-Type' => 'text/plain'], "case1");
	} elsif ( $num == 2 ) {
		return lambda { HTTP::Response->new(200, 'OK', ['Content-Type' => 'text/plain'], "case2"); };
	} elsif ( $num == 3 ) {
		return undef, "case3";
	}
} "localhost:$port";
plan skip_all => "listen error: $error" unless $server;
$server->start;


# single
my $r = http_lambda('www.google.com')-> wait;
plan skip_all => "connect error: $r. Offline?" if !ref($r) && $r =~ /connect/;
ref($r) ? ok(1,"http_get(google)") : ok(0,"http_get(google):$r");

# many
lambda {
	context map { http_lambda('www.google.com') } 1..3;
	tails { ok(( 3 == grep { ref($_) } @_), 'parallel resolve') }
}-> wait;

# local
$opt{proxy} = undef;
my $resp = http_lambda("localhost:$port")->wait;
is( $resp->code, "200", "httpd simple code");
is( $resp->content, "case1", "httpd simple response");
$resp = http_lambda("localhost:$port")->wait;
is( $resp->code, "200", "httpd lambda code");
is( $resp->content, "case2", "httpd lambda response");
$resp = http_lambda("localhost:$port")->wait;
is( $resp->code, "500", "httpd error code");
is( $resp->content, "case3", "httpd error response");

$r = HTTP::Request-> new( GET => "http://localhost:$port/");

$num = 0;
my $conn_cache = LWP::ConnCache->new;
$resp = IO::Lambda::HTTP::Client->new($r, keep_alive => 1, conn_cache => $conn_cache, proxy => undef)->wait;
is( $resp->code, "200", "httpd keep_alive code");
is( $resp->content, "case1", "httpd keep_alive response");
is( scalar $conn_cache->get_connections(), 1, "1 active connection");
$resp = IO::Lambda::HTTP::Client->new($r, keep_alive => 1, conn_cache => $conn_cache, proxy => undef)->wait;
is( $resp->code, "200", "httpd keep_alive code");
is( $resp->content, "case2", "httpd keep_alive response");

done_testing;
