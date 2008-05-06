# $Id: DNS.pm,v 1.1 2008/05/06 14:19:12 dk Exp $
package IO::Lambda::DNS;
use vars qw($DEBUG $TIMEOUT $RETRIES @ISA);
@ISA = qw(Exporter);
@EXPORT_OK = qw(dns_query dns_lambda);
%EXPORT_TAGS = ( all => \@EXPORT_OK);
$TIMEOUT = 4.0; # seconds
$RETRIES = 4;   # times

use Time::HiRes;
use Net::DNS::Resolver;
use IO::Lambda qw(:all);

# given the options, returns new dns lambda

sub dns_lambda
{
	# get the options
	my @ctx;
	my $timeout  = $TIMEOUT;
	my $retries  = $RETRIES;
	my %opt;
	for ( my $i = 0; $i < @_; $i++) {
		if ( $i == 0 or $i == $#_ or not defined($_[$i])) {
			# first or last or undef parameter in no way can be an option
			push @ctx, $_[$i];
		} elsif ( $_[$i] eq 'timeout') {
			$timeout  = $_[++$i];
		} elsif ( $_[$i] eq 'retry') {
			$retries  = $_[++$i];
		} elsif ( $_[$i] =~ /^(
			nameservers|recurse|debug|config_file|
			domain|port|srcaddr|srcport|retrans|
			usevc|stayopen|igntc|defnames|dnsrch|
			persistent_tcp|persistent_udp|dnssec
		)$/x) {
			$opt{$_[$i]} = $_[$i + 1];
			$i++;
		} else {
			push @ctx, $_[$i];
		}
	}

	# proceed
	lambda {
		my $obj  = Net::DNS::Resolver-> new( %opt);
		my $sock = $obj-> bgsend( @ctx);
		return "send error: " . $obj-> errorstring unless $sock;

		context $sock, defined($timeout) ? time + $timeout : undef;
	read {
		unless ( shift) {
			return 'connect timeout' if $retries-- <= 0;
			return this-> start; # restart the whole lambda
		}

		my $err = unpack('i', getsockopt($sock, SOL_SOCKET, SO_ERROR));
		if ( $err) {
			$! = $err;
			return "socket error: $!";
		}
		return again unless $obj-> bgisready($sock);

		my $packet = $obj-> bgread( $sock);
		undef $sock;
		
		return "recv error: " . $obj-> errorstring unless $packet;

		return $packet;
	}};
}

sub dns_query(&)
{
	this-> add_tail( 
		shift, 
		\&dns_query, 
		dns_lambda(context), 
		context
	)
}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::DNS - DNS queries lambda style

=head1 DESCRIPTION

The module provides access to asynchronous DNS queries through L<Net::DNS>.
Two names doing the same function are exported: predicate-style C<dns_query> 
and lambda-style C<dns_lambda>.

=head1 SYNOPSIS

   use strict;
   use IO::Lambda::DNS qw(:all);
   use IO::Lambda qw(:all);

   # single async query
   my $reply = dns_lambda( "www.site.com" )-> wait;
   print ref($reply) ? $reply-> string : "Error: $reply\n";

   # parallel async queries -- create many lambdas, wait with tails() for them all
   my @replies = lambda {
       context map { 
           dns_lambda( $_, timeout => 1, retry => 3);
       } @hostnames;
       \&tails;
   }-> wait;

   # again parallel async queries -- within single lambda, fire-and-forget
   for my $site ( map { "www.$_.com" } qw(google yahoo perl)) {
        context $site, nameservers => ['127.0.0.1'], timeout => 0.25;
   	dns_query { print shift-> string if ref($_[0]) }
   }

=head2 OPTIONS

Accepted options specific to the module are C<timeout> (in seconds) and C<retry> (in times).
All other options, such as C<nameservers>, C<dnssec> etc etc are passed as is
to the C<Net::DNS::Resolver> constructor. See its man page for details.

=head1 SEE ALSO

L<IO::Lambda>, L<Net::DNS::Resolver>.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
