#!/usr/bin/perl
# $Id: sequential.pl,v 1.1 2007/12/11 14:48:38 dk Exp $
# 
# This example fetches sequentially two pages, one with http/1.0 another with
# https/1.1 . The idea is to demonstrate three different ways of doing so, by
# using object API, and explicit and implicit loop unrolling
#

use lib qw(./lib);
use HTTP::Request;
use IO::Lambda qw(:all);
use IO::Lambda::HTTP qw(http_get);
use IO::Lambda::HTTPS qw(https_get);

my $a = HTTP::Request-> new(
	GET => "https://addons.mozilla.org/en-US/firefox",
);
$a-> protocol('HTTP/1.1');
$a-> headers-> header( Host => 'addons.mozilla.org');
$a-> headers-> header( Connection => 'close');

my @chain = (
	https_get( $a),
	http_get( HTTP::Request-> new(GET => "http://www.perl.com/")),
);

sub report
{
	my ( $result) = @_;
	if ( ref($result) and ref($result) eq 'HTTP::Response') {
		print "good:", length($result-> content), "\n";
	} else {
		print "bad:$result\n";
	}
#	print $result-> content;
}

my $style;
$style = 'object';
#$style = 'explicit';
#$style = 'implicit';

# $IO::Lambda::DEBUG++; # uncomment this to see that it indeed goes sequential

if ( $style eq 'object') {

	# object API, all references and bindings are explicit
	sub handle
	{
		my ( $q, $result) = @_;
		report($result);
		shift(@chain)-> tail( \&handle) if @chain;
	}
	shift(@chain)-> tail( \&handle);

} elsif ( $style eq 'explicit') {

	#
	# Functional API, based on context() calls. context is
	# $obj and whatever agruments the current call needs, a RPN of sorts.
	# The context though is not stack in this analogy, because it stays
	# as is in the callback
	#
	# Explicit loop unrolling - we know that we have exactly 2 steps
	# It's not practical in this case, but it is when a (network) protocol
	# relies on precise series of reads and writes
	self( $chain[0]);
	finally {
		report(shift);
	
	self( $chain[1]);
	finally {
		report(shift);
	}};

} else {
	# implicit loop - we don't know how many states we need
	self( shift @chain);
	finally {
		report(shift);
		return unless @chain;
		self(shift @chain);
		again;
	};
}
run IO::Lambda::Loop;
