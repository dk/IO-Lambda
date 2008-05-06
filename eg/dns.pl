# $Id: dns.pl,v 1.1 2008/05/06 14:19:12 dk Exp $
use strict;
use Net::DNS;
use IO::Lambda::DNS qw(:all);
use IO::Lambda qw(:lambda);

sub show
{
	my $res = shift;
	unless ( ref($res)) {
		print "$res\n";
		return;
	}

	for ( $res-> answer) {
		if ( $_-> type eq 'CNAME') {
			print "CNAME: ", $_-> cname, "\n";
		} elsif ( $_-> type eq 'A') {
			print "A: ", $_-> address, "\n";
		} else {
			$_-> print;
		}
	}
}

# style one -- dns_query() is a predicate
lambda {
	for my $site ( map { "www.$_.com" } qw(google yahoo perl)) {
		context $site,
			timeout => 1.0, 
			retry => 1;
		dns_query { show(@_) }
	}
}-> wait;

print "--------------\n";

# style two -- dns_lambda returns a lambda
lambda {
	context map { dns_lambda( "www.$_.com" ) } qw(google perl yahoo);
	tails { show($_) for @_ };
}-> wait;
