#!/usr/bin/perl
# $Id: parallel.pl,v 1.3 2007/12/14 20:27:05 dk Exp $
# 
# This example fetches two pages in parallel, one with http/1.0 another with
# https/1.1 . The idea is to demonstrate three different ways of doing so, by
# using object API, and explicit and implicit loop unrolling
#

use lib qw(./lib);
use HTTP::Request;
use IO::Lambda qw(:all);
use IO::Lambda::HTTP qw(http_request);

my $a = HTTP::Request-> new(
	GET => "http://www.perl.com/",
);
$a-> protocol('HTTP/1.1');
$a-> headers-> header( Host => $a-> uri-> host);
$a-> headers-> header( Connection => 'close');

my @chain = ( 
	$a, 
	HTTP::Request-> new(GET => "http://www.perl.com/"),
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
#$style = 'object';
#$style = 'explicit';
$style = 'implicit';

# $IO::Lambda::DEBUG++; # uncomment this to see that it indeed goes parallel

if ( $style eq 'object') {
	## object API, all references and bindings are explicit
	sub handle {
		shift;
		report(@_);
	}
	my $master = IO::Lambda-> new;
	for ( @chain) {
		my $lambda = IO::Lambda::HTTP-> new( $_ );
		$master-> watch_lambda( $lambda, \&handle);
	}
	run IO::Lambda;
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
	this lambda {
		context $chain[0];
		http_request \&report;
		context $chain[1];
		http_request \&report;
	};
	this-> wait;
} else {
	# implicit loop - we don't know how many states we need
	# 
	# also, use 'tail'
	this lambda {
		context map {
			lambda {
				context shift;
				&http_request;
			}-> call($_);
		} @chain;
		tail { report $_ for @_ };
	};
	this-> wait;
}

