package IO::Lambda::HTTP;
use vars qw(@ISA @EXPORT_OK);
@ISA = qw(Exporter IO::Lambda);
@EXPORT_OK = qw(http_get);

use strict;
use warnings;
use Socket;
use Exporter;
use IO::Socket;
use HTTP::Response;
use IO::Lambda qw(:all);

sub http_get { __PACKAGE__-> new( @_ ) } # export

sub new
{
	my ( $class, $req, %options) = @_;
	my $self = $class-> SUPER::new( %options );

	$self-> {deadline}     = $options{timeout} + time if defined $options{timeout};
	$self-> {max_redirect} = defined($options{max_redirect}) ? $options{max_redirect} : 7;

	$self-> redirect_request($req);

	return $self;
}

sub uri_to_socket
{
	my ( $self, $uri) = @_;

	my $sock = IO::Socket::INET-> new(
		Blocking => 0,
		PeerAddr => $uri-> host,
		PeerPort => $uri-> port,
		Proto    => 'tcp',
	);

	return $sock ? $sock : (undef, $!);

}

sub redirect_request
{
	my ( $self, $req) = @_;

	my $uri          = $req-> uri;
	my ($sock, $err) = $self-> uri_to_socket( $uri);
	unless ( $sock) {
		$self-> fail( "Error creating socket: $err");
		return;
	}

	my $q = IO::Lambda-> new;
	$self-> single_request( $q, $sock, $req-> as_string);

	my $was_redirected = 0;

	self_context($self, $q);
	pipeline {
		my $response = shift;
		return $response unless ref($response);
		return $response if $response-> code ne '302' and $response-> code ne '301';

		return 'too many redirects' 
			if ++$was_redirected > $self-> {max_redirect};

		$req-> uri( $response-> header('Location'));
		$uri          = $req->  uri;
		($sock, $err) = $self-> uri_to_socket( $uri);
		return "Error creating socket: $err" unless $sock;

		push_context;
		$self-> single_request( $q, $sock, $req-> as_string);
		pop_context;
		
		again;
	};
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
		print $sock $request or return "write error:$!";

	read {
		return 'timeout' unless shift;
		my $n = sysread( $sock, $buf, 32768, length($buf));
		return "read error:$!" unless defined $n;
		return again if $n;
		return $self-> parse( \$buf);
	}};

	return $q;
}

sub parse
{
	my ( $self, $buf_ptr) = @_;
	return HTTP::Response-> parse( $$buf_ptr);
}

1;
