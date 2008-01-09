# $Id: HTTP.pm,v 1.11 2008/01/09 11:47:18 dk Exp $
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
	$self-> {conn_cache}   = $options{conn_cache};
		
	$req-> headers-> header( 'User-Agent' => "perl/IO-Lambda-HTTP v$IO::Lambda::VERSION")
		unless defined $req-> headers-> header('User-Agent');

	return $self-> handle_redirects( $req);
}

# execute a single http request over an established connection
sub http_protocol
{
	my ( $self, $req, $sock, $cached) = @_;

	lambda {
		print $sock $req-> as_string or return "write error:$!";

		my $buf = '';
		context $sock, $self-> {deadline};
	read {
		return 'timeout' unless shift;

		my $n = sysread( $sock, $buf, 32768, length($buf));
		return "read error:$!" unless defined $n;

		return $self-> parse( \$buf) if $self-> got_content(\$buf);
		return again if $n;
		return $self-> parse( \$buf);
	}};
}

sub init_request
{
	my ( $self) = @_;

	delete @{$self}{qw(want_no_headers got_headers want_length close_connection chunked want_chunk)};
}

# get scheme and eventually load module
my $got_https;
sub get_protocol
{
	my ( $self, $req) = @_;
	my $protocol;
	my $scheme = $req-> uri-> scheme;
	if ( $scheme eq 'https') {
		unless ( $got_https) {
			eval { require IO::Lambda::HTTPS; };
			return undef, "https not supported: $@" if $@;
			$got_https++;
		}
		$protocol = \&IO::Lambda::HTTPS::https_protocol;
	} elsif ( $scheme ne 'http') {
		return ( undef, "bad URI scheme: $scheme");
	} else {
		$protocol = \&http_protocol;
	}

	return $protocol;
}

sub connect
{
	my ( $self, $host, $port) = @_;

	return IO::Socket::INET-> new(
		PeerAddr => $host,
		PeerPort => $port,
		Proto    => 'tcp',
		Blocking => 0,
	), $!;
}

# connect to the remote, execute a single http or https request
sub handle_request
{
	my ( $self, $req) = @_;

	# have a chance to load eventual modules early
	my ( $protocol, $err) = $self-> get_protocol( $req);
	
	lambda {
		return $err unless $protocol;

		$self-> init_request;

		# get cached socket?
		my ( $sock, $cached);
		my $cc = $self-> {conn_cache};
		my ( $host, $port) = ( $req-> uri-> host, $req-> uri-> port);
		if ( $cc) {
			$sock = $cc-> withdraw( __PACKAGE__, "$host:$port");
			if ( $sock) {
				my $err = unpack('i', getsockopt( $sock, SOL_SOCKET, SO_ERROR));
				$err ? undef $sock : $cached++;
			}
		}

		# connect
		( $sock, $err) = $self-> connect( $host, $port) unless $sock;
		return $err unless $sock;
		context( $sock, $self-> {deadline});

	write {
		# connected
		return 'connect timeout' unless shift;
		my $err = unpack('i', getsockopt($sock, SOL_SOCKET, SO_ERROR));
		return "connect error:$err" if $err;

		context $protocol-> ( $self, $req, $sock, $cached);
	tail {
		# protocol finished
		my $result = shift;
		$cc-> deposit( __PACKAGE__, "$host:$port", $sock)
			if ref($result) and $cc and not $self-> {close_connection};
		return $result;
	}}}
}

# 
sub handle_redirects
{
	my ( $self, $req) = @_;
		
	my $was_redirected = 0;

	lambda {
		context $self-> handle_request( $req);
	tail   {
		# request is finished
		my $response = shift;
		return $response unless ref($response);

		return $response if $response-> code ne '302' and $response-> code ne '301';
		return 'too many redirects' 
			if ++$was_redirected > $self-> {max_redirect};
		
		$req-> uri( $response-> header('Location'));
		$req-> headers-> header( Host => $req-> uri-> host);

		context $self-> handle_request( $req);
		again;
	}};
}


# peek into buffer and see: 
# 1: if we have Content-Length in headers and we have that many bytes
# 2: if we have Transfer-Encoding: chunked in headers and we have read all chunks
# 3: if we're asked to Connection: close just in case when we keep the connection
sub got_content
{
	my ( $self, $buf) = @_;

	return if $self-> {want_no_headers};

	unless ( $self-> {got_headers}) {
		return unless $$buf =~ /\n/;

		unless ( $$buf =~ /^HTTP\S+\s+\d{3}\s+/i) {
			$self-> {want_no_headers}++;
			return;
		}

		# no headers yet
		return unless $$buf =~ /^(.*?\r?\n\r?\n)/s;

		$self-> {got_headers} = 1;
		my $headers  = $1;
		my $appendix = length($headers);
		$headers = HTTP::Response-> parse( $headers);

		# Connection: close
		my $c = lc( $headers-> header('Connection') || '');
		$self-> {close_connection} = $c =~ /^close\s*$/;
		
		# Transfer-Encoding: chunked
		my $te = lc( $headers-> header('Transfer-Encoding') || '');
		if ( $self-> {chunked} = $te =~ /^chunked\s*$/) {
			$self-> {want_chunk} = $appendix;
			return 1 if $self-> got_te( $buf);
		}

		# Content-Length
		my $l = $headers-> header('Content-Length');
		return unless defined ($l) and $l =~ /^(\d+)\s*$/;
		$self-> {want_length} = $1 + $appendix;
	} 
	
	if ( defined $self-> {want_length}) {
		# check if got enough using Content-Length
 		return length($$buf) >= $self-> {want_length};
	}
	
	if ( $self-> {chunked}) {
		# check if got enough using Transfer-Encoding: chunked
		return 1 if $self-> got_te( $buf);
	}

	return 0;
}

# checks if Transfer-Encoding: chunked produced enough data to close connection
sub got_te
{
	my ( $self, $buf) = @_;

	# walk through all available chunks, advance want_chunk pointer
	while ( 1) {
		return if length($$buf) < $self-> {want_chunk};

		# got chunk size?
		pos( $$buf) = $self-> {want_chunk};
		return unless $$buf =~ /\G(.*?)\r?\n/g;
		my $size = $1;
		unless ( $size =~ /^([\da-f]+)/i) {
			# not a chunk size, won't continue in chunk mode
			$self-> {chunked} = 0;
			return;
		}
		$size = hex $size;

		# enough!
		return 1 if $size == 0;

		$self-> {want_chunk} = pos($$buf) + $size + 2; # 2 for CRLF
	}
}

sub parse
{
	my ( $self, $buf_ptr) = @_;
	return HTTP::Response-> parse( $$buf_ptr) if $$buf_ptr =~ /^(HTTP\S+)\s+(\d{3})\s+/i;
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
   use LWP::ConnCache;
   

   # prepare http request
   my $req = HTTP::Request-> new( GET => "http://www.perl.com/");
   $req-> protocol('HTTP/1.1');
   $req-> headers-> header( Host => $req-> uri-> host);

   # connection cache (optional)
   my $cache = LWP::ConnCache-> new;
   
   this lambda {
      context shift, conn_cache => $cache;
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

=item conn_cache $LWP::ConnCache = undef

Can optionally use a C<LWP::ConnCache> object to reuse connections on per-host per-port basis.
See L<LWP::ConnCache> for details.

=back

=head1 SEE ALSO

L<IO::Lambda>, L<HTTP::Request>, L<HTTP::Response>

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
