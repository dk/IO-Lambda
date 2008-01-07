# $Id: HTTP.pm,v 1.8 2008/01/07 10:08:21 dk Exp $
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
use Time::HiRes qw(time);

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
	return HTTP::Response-> parse( $$buf_ptr) if $$buf_ptr =~ /^(\S+)\s+(\d{3})\s+/;
	return HTTP::Response-> new( '000', '', undef, $$buf_ptr);
}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::HTTP - http requests lambda style

=head1 DESCRIPTION

The module exports a single predicate C<http_request> that accepts a
C<HTTP::Request> object and set of options as parameters. Returns either a
C<HTTP::Response> on success, or error string otherwise.

=head1 SYNOPSIS

   use HTTP::Request;
   use IO::Lambda qw(:all);
   use IO::Lambda::HTTP qw(http_request);
   
   my $req = HTTP::Request-> new( GET => "http://www.perl.com/");
   $req-> protocol('HTTP/1.1');
   $req-> headers-> header( Host => $req-> uri-> host);
   $req-> headers-> header( Connection => 'close');
   
   this lambda {
      context shift;
      http_request {
         my $result = shift;
         if ( ref($result)) {
            print "good:", length($result-> content), "\n";
         } else {
            print "bad:$result\n";
         }
      }
   };

   this-> wait($req);

=head1 API

=over

=item http_request $HTTP::Request

C<http_request> is a lambda predicate that accepts C<HTTP::Request> object in
the context. Returns either a C<HTTP::Response> object on success, or error
string otherwise.

=item new $HTTP::Request

Stores C<HTTP::Request> object and returns a new lambda that will finish 
when the request associated with it completes. The lambda callback will
be passed either a C<HTTP::Response> object on success, or error
string otherwise. 

=back

=head1 OPTIONS

=over

=item timeout SECONDS = undef

Maximum allowed time the request can take. If undef, no timeouts occur.

=item max_redirect NUM = 7

Maximum allowed redirects. If 1, no redirection attemps are made.

=back

=head1 SEE ALSO

L<IO::Lambda>, L<HTTP::Request>, L<HTTP::Response>

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
