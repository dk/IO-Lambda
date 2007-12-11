# $Id: HTTPS.pm,v 1.1 2007/12/11 14:48:38 dk Exp $
package IO::Lambda::HTTPS;

use vars qw(@ISA @EXPORT_OK);
@ISA = qw(Exporter IO::Lambda::HTTP);
@EXPORT_OK = qw(https_get);

use strict;
use warnings;
use Exporter;
use IO::Socket::SSL;
use IO::Lambda qw(:all);
use IO::Lambda::HTTP;
use Socket;

sub https_get { __PACKAGE__-> new( @_ ) } # export

sub uri_to_socket
{
	my ( $self, $uri) = @_;

	my $sock = IO::Socket::SSL-> new(
		Blocking => 0,
		PeerAddr => $uri-> host,
		PeerPort => $uri-> port,
		Proto    => 'tcp',
	);

	return $sock ? $sock : ( undef, $@);
}

sub single_request
{
	my ( $self, $q, $sock, $request) = @_;

	my $buf = '';

	self_context( $q, $sock, $self-> {deadline});

	write {
		return 'connect timeout' unless shift;
		my $err = unpack('i', getsockopt($sock, SOL_SOCKET, SO_ERROR));
		return "connect error:$err" if $err;

		unless ( print $sock $request) {
			return again if $SSL_ERROR == SSL_WANT_WRITE;
			return "write error:$!";
		}
	read {
		return 'timeout' unless shift;

		my $n = sysread( $sock, $buf, 32768, length($buf));
		return again if not defined $n and $SSL_ERROR == SSL_WANT_READ;
		return "read error:$!" unless defined $n;
		return again if $n;

		return $self-> parse( \$buf);
	}};
}


1;
