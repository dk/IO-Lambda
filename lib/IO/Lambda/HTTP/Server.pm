package IO::Lambda::HTTP::Server;
use vars qw(@ISA @EXPORT_OK $DEBUG);
@ISA = qw(Exporter);
@EXPORT = qw(http_server);

our $DEBUG = $IO::Lambda::DEBUG{httpd} || 0;

use strict;
use warnings;
use Socket;
use Exporter;
use IO::Socket::INET;
use HTTP::Request;
use HTTP::Response;
use IO::Lambda qw(:lambda :stream);
use IO::Lambda::Socket qw(accept);
use Time::HiRes qw(time);

my $CRLF = "\x0d\x0a";
sub http_server(&$;)
{
	my ( $cb, $listen, %opt) = @_;

	my $port = 80;
	unless ( ref $listen ) {
		($listen, $port) = ($1, $2) if $listen =~ /^(.*)\:(\d+)$/;
		$listen = IO::Socket::INET->new(
			Listen => 5,
			LocalAddr => $listen,
			LocalPort => $port,
			Proto     => 'tcp',
			ReuseAddr => 1,
			ReusePort => 1,
		);
		unless ( $listen ) {
			warn "$!\n";
			return;
		}
	} else {
		$port = $listen->sockport;
	}

	return lambda {
		context $listen;
		accept {
			my $conn = shift;
			again;

			unless ( ref($conn)) {
				warn "accept() error:$conn\n" if $DEBUG;
				return;
			}
			if ( $DEBUG ) {
       				my $hostname = inet_ntoa((sockaddr_in(getsockname($conn)))[1]);
				warn "[$hostname] connect\n";
			}
			$conn-> blocking(0);

			my $buf = '';
			context readbuf, $conn, \$buf, qr/^.*?$CRLF$CRLF/s, $opt{timeout};
		tail {
			my ( $match, $error) = @_;
			unless (defined $match) {
				warn "$error\n" if $DEBUG;
				close($conn);
				return;
			}
			warn length($buf), " bytes read\n" if $DEBUG > 1;
			my $req = HTTP::Request-> parse( $match);
			unless ($req) {
				warn "bad request\n" if $DEBUG;
				close($conn);
				return;
			}

			my $cl = length($match) + ($req->header('Content-Length') // 0);
			context (($cl > length($buf)) ?
				(readbuf, $conn, \$buf, $cl, $opt{conn_timeout}) :
				lambda {});
		tail {
			my ( undef, $error) = @_;
			if (defined $error) {
				warn "bad request\n" if $DEBUG;
				close($conn);
				return;
			}
			warn length($buf), " bytes read\n" if $DEBUG > 1;
			$req = HTTP::Request-> parse( $buf);
			my $resp;
			($resp, $error) = $cb->($req);
			context UNIVERSAL::isa( $resp, 'IO::Lambda') ?
				$resp : lambda { $resp, $error };
		tail {
			my $error;
			($resp, $error) = @_;
			if ( $error ) {
				$resp = "HTTP/1.1 500 Server Error${CRLF}Content-Length: ".length($error) . "$CRLF$CRLF" . $error;
			} elsif ( UNIVERSAL::isa( $resp, 'HTTP::Response')) {
				$resp = "HTTP/1.1 " . $resp->as_string($CRLF);
			} else {
				$resp = "HTTP/1.1 200 OK${CRLF}Content-Length: ".length($resp) . "$CRLF$CRLF" . $resp;
			}
			context writebuf, $conn, \$resp, length($resp), 0, $opt{timeout};
		tail {
			my ( undef, $error) = @_;
			if (defined $error) {
				warn "error during response:$error\n" if $DEBUG;
				close($conn);
				return;
			}
			if ( !close($conn)) {
				warn "error during response:$!\n" if $DEBUG;
				return;
			}
			warn length($resp), " bytes written\n" if $DEBUG > 1;
		}}}}}
	};
}

1;

=head1 NAME

IO::Lambda::HTTP::Server - simple httpd server

=head1 DESCRIPTION

The module exports a single function C<http_server> that accepts a callback
and a socket, with optional parameters. The callback accepts a C<HTTP::Request>
object, and is expected to return either a C<HTTP::Response> object or a lambda
that in turn returns a a C<HTTP::Response> object.

=head1 SYNOPSIS

   use HTTP::Request;
   use IO::Lambda qw(:all);
   use IO::Lambda::HTTP qw(http_request);
   use IO::Lambda::HTTP::Server;

   my $server = http_server {
        my $req = shift;
	if ( $req->uri =~ /weather/) {
                context( HTTP::Request-> new( GET => "http://www.google.com/?q=weather"));
		return &http_request;
	} else {
   		return HTTP::Response->new(200, 'OK', ['Content-Type' => 'text/plain'], "hello world");
	}
   } "localhost:80"; 
   $server->start; # runs in 'background' now

=head1 API

=over
 
=item http_server &callback, $socket, [ %options ]

Creates lambda that listens on C<$socket>, that is either a C<IO::Socket::INET> object
or a string such as C<"localhost"> or C<"127.0.0.1:9999">. 

The callback accepts a C<HTTP::Request> object, and is expected to return
either a C<HTTP::Response> object or a lambda that in turn returns a a
C<HTTP::Response> object.

Options:

=over

=item timeout $integer

Connection timeout or a deadline.

=back

=back

=head1 SEE ALSO

L<IO::Lambda>, L<HTTP::Request>, L<HTTP::Response>

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
