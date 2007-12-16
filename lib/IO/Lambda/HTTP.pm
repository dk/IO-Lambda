# $Id: HTTP.pm,v 1.4 2007/12/16 17:18:57 dk Exp $
package IO::Lambda::HTTP;
use vars qw(@ISA @EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT_OK = qw(http_request);

use strict;
use warnings;
use Socket;
use Exporter;
use IO::Socket;
use HTTP::Response;
use IO::Lambda qw(:all);

sub http_request(&)
{
	this-> add_tail(
		shift,
		\&http_request,
		__PACKAGE__-> new( context ),
		context
	);
}

sub new
{
	my ( $class, $req, %options) = @_;

	my $self = bless {}, $class;

	$self-> {deadline}     = $options{timeout} + time if defined $options{timeout};
	$self-> {max_redirect} = defined($options{max_redirect}) ? $options{max_redirect} : 7;

	return $self-> redirect_request( $req);
}

sub uri_to_socket
{
	my ( $self, $uri) = @_;

	my $sock = IO::Socket::INET-> new(
		PeerAddr => $uri-> host,
		PeerPort => $uri-> port,
		Proto    => 'tcp',
	);

	return $sock ? $sock : (undef, $!);
}

sub redirect_request
{
	my ( $self, $req) = @_;

	lambda {
		my $was_redirected = 0;

		context( $self-> single_request( $req));
	tail   {
		my $response = shift;
		return $response unless ref($response);
		return $response if $response-> code ne '302' and $response-> code ne '301';
		return 'too many redirects' 
			if ++$was_redirected > $self-> {max_redirect};
		
		$req-> uri( $response-> header('Location'));
		$req-> headers-> header( Host => $req-> uri-> host);

		context( $self-> single_request( $req));
		again;
	}};
}

sub single_request
{
	my ( $self, $req) = @_;

	lambda {
		my ($sock, $err) = $self-> uri_to_socket( $req-> uri);
		return "Error creating socket:$err" unless $sock;

		context( $sock, $self-> {deadline});
	write {
		return 'connect timeout' unless shift;
		my $err = unpack('i', getsockopt($sock, SOL_SOCKET, SO_ERROR));
		return "connect error:$err" if $err;
		print $sock $req-> as_string or return "write error:$!";

		my $buf = '';
	read {
		return 'timeout' unless shift;

		my $n = sysread( $sock, $buf, 32768, length($buf));
		return "read error:$!" unless defined $n;
		return again if $n;
		return $self-> parse( \$buf);
	}}};
}

sub parse
{
	my ( $self, $buf_ptr) = @_;
	return HTTP::Response-> parse( $$buf_ptr);
}

1;
