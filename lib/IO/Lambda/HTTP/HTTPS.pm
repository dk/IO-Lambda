# $Id: HTTPS.pm,v 1.4 2007/12/16 20:20:16 dk Exp $
package IO::Lambda::HTTPS;

use vars qw(@ISA @EXPORT_OK);
@ISA = qw(Exporter IO::Lambda::HTTP);
@EXPORT_OK = qw(https_request);

use strict;
use warnings;
use Exporter;
use IO::Socket::SSL;
use IO::Lambda qw(:all);
use IO::Lambda::HTTP;
use Socket;

sub https_request(&)
{
	this-> add_tail(
		shift,
		\&https_request,
		__PACKAGE__-> new( context ),
		context
	);
}


sub uri_to_socket
{
	my ( $self, $uri) = @_;

	my $sock = IO::Socket::SSL-> new(
		PeerAddr => $uri-> host,
		PeerPort => $uri-> port,
		Proto    => 'tcp',
	);

	return $sock ? $sock : ( undef, $@);
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

		unless ( print $sock $req-> as_string) {
			return again if $SSL_ERROR == SSL_WANT_WRITE;
			return "write error:$!";
		}

		my $buf = '';
	read {
		return 'timeout' unless shift;

		my $n = sysread( $sock, $buf, 32768, length($buf));
		return again if not defined $n and $SSL_ERROR == SSL_WANT_READ;
		return "read error:$!" unless defined $n;
		return again if $n;

		return $self-> parse( \$buf);
	}}};
}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::HTTPS - https requests lambda style

=head1 DESCRIPTION

The module exports a single lambda C<https_request> that behaves exactly
as C<IO::Lambda::HTTP::http_request>. See L<IO::Lambda::HTTP> for detailed
explanation of the behavior.

=head1 SYNOPSIS

   use HTTP::Request;
   use IO::Lambda qw(:all);
   use IO::Lambda::HTTP qw(https_request);
   
   my $r = HTTP::Request-> new( GET => "https://addons.mozilla.org/en-US/firefox");
   $req-> protocol('HTTP/1.1');
   $req-> headers-> header( Host => $a-> uri-> host);
   $req-> headers-> header( Connection => 'close');
   
   this http_request {
      my $res = shift;
      if ( ref($result)) {
         print "good:", length($result-> content), "\n";
      } else {
         print "bad:$result\n";
      }
   };

   this-> wait;

=head1 SEE ALSO

L<IO::Lambda::HTTP>

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
