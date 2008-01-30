# $Id: HTTP.pm,v 1.19 2008/01/30 13:20:09 dk Exp $
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
use IO::Lambda qw(:lambda :stream);
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

	$self-> {timeout}      = $options{deadline}       if defined $options{deadline};
	$self-> {deadline}     = $options{timeout} + time if defined $options{timeout};
	$self-> {max_redirect} = defined($options{max_redirect}) ? $options{max_redirect} : 7;
	$self-> {conn_cache}   = $options{conn_cache};
		
	$req-> headers-> header( 'User-Agent' => "perl/IO-Lambda-HTTP v$IO::Lambda::VERSION")
		unless defined $req-> headers-> header('User-Agent');

	return $self-> handle_redirect( $req);
}

# reissue the request if it request returns 30X code
sub handle_redirect
{
	my ( $self, $req) = @_;
		
	my $was_redirected = 0;

	lambda {
		context $self-> handle_connection( $req);
	tail   {
		# request is finished
		my $response = shift;
		return $response unless ref($response);

		return $response unless $response-> code =~ /^3/;
		return 'too many redirects' 
			if ++$was_redirected > $self-> {max_redirect};
		
		$req-> uri( $response-> header('Location'));
		$req-> headers-> header( Host => $req-> uri-> host);

		context $self-> handle_request( $req);
		again;
	}};
}

# get scheme and eventually load module
my $got_https;
sub prepare_transport
{
	my ( $self, $req) = @_;
	my $scheme = $req-> uri-> scheme;

	if ( $scheme eq 'https') {
		unless ( $got_https) {
			eval { require IO::Lambda::HTTPS; };
			return  "https not supported: $@" if $@;
			$got_https++;
		}
		$self-> {reader} = IO::Lambda::HTTPS::https_reader();
		$self-> {writer} = \&IO::Lambda::HTTPS::https_writer;
	} elsif ( $scheme ne 'http') {
		return "bad URI scheme: $scheme";
	} else {
		$self-> {reader} = undef;
		$self-> {writer} = undef;
	}

	return;
}

sub http_read
{
	my ( $self, $cond) = @_;
	return $self-> {reader}, $self-> {socket}, \ $self-> {buf}, $cond, $self-> {deadline};
}

sub http_tail
{
	my ( $self, $cond) = @_;
	context $self-> http_read($cond);
	&tail();
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

# Connect to the remote, wait for protocol to finish, and
# close the connection if needed. Returns HTTP::Reponse object on success
sub handle_connection
{
	my ( $self, $req) = @_;

	# have a chance to load eventual modules early
	my $err = $self-> prepare_transport( $req);
	
	lambda {
		return $err if defined $err;

		delete $self-> {close_connection};

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
		my $err;
		( $sock, $err) = $self-> connect( $host, $port) unless $sock;
		return $err unless $sock;
		context( $sock, $self-> {deadline});

	write {
		# connected
		return 'connect timeout' unless shift;
		my $err = unpack('i', getsockopt($sock, SOL_SOCKET, SO_ERROR));
		if ( $err) {
			$! = $err;
			return "connect: $!";
		}

		$self-> {buf}    = '';
		$self-> {socket} = $sock;
		$self-> {reader} = readbuf ( $self-> {reader});
		$self-> {writer} = $self-> {writer}-> ($cached) if $self-> {writer}; 
		$self-> {writer} = writebuf( $self-> {writer});

		context $self-> handle_request( $req);
	tail {
		my ( undef, $error) = @_; # readbuf style
		
		# protocol is finished
		my $ret = defined($error) ? $error : $self-> parse( \ $self-> {buf} );
		delete @{$self}{qw(close_connection socket buf writer reader)};

		# put back the connection, if possible
		if ( $cc and not $self-> {close_connection}) {
			my $err = unpack('i', getsockopt( $sock, SOL_SOCKET, SO_ERROR));
			$cc-> deposit( __PACKAGE__, "$host:$port", $sock)
				unless $err;
		}
		return $ret;
	}}}
}

# Execute single http request over an established connection.
# Returns 2 parameters, readbuf-style, where actually only the 2nd matters,
# and signals error if defined. 2 parameters are there for readbuf compatibility,
# so protocol handler can easily fall back to readbuf itself.
sub handle_request
{
	my ( $self, $req) = @_;

	lambda {
		# send request
		$req = $req-> as_string;
		context 
			$self-> {writer}, 
			$self-> {socket}, \ $req, 
			undef, 0, $self-> {deadline};
	tail {
		my ( $bytes_written, $error) = @_;
		return undef, $error if $error;

		context $self-> {socket}, $self-> {deadline};
	read {
		# request sent, now wait for data
		return undef, 'timeout' unless shift;
		
		# read first line
		context $self-> http_read(qr/^.*?\n/);
	tail {
		my $line = shift;
		return undef, shift unless defined $line;

		# no headers? 
		return $self-> http_tail
			unless $line =~ /^HTTP\/([\.\d]+)\s+(\d{3})\s+/i;
		
		my ( $proto, $code) = ( $1, $2);
		# got some headers
		context $self-> http_read( qr/^.*?\r?\n\r?\n/s);
	tail {
		$line = shift;
		return undef, shift unless defined $line;

		my $headers = HTTP::Response-> parse( $line);
		my $offset  = length( $line);

		# Connection: close
		my $c = lc( $headers-> header('Connection') || '');
		$self-> {close_connection} = $c =~ /^close\s*$/i;
		
		# have Content-Length? read that many bytes then
		my $l = $headers-> header('Content-Length');
		return $self-> http_tail( $1 + $offset )
			if defined ($l) and $l =~ /^(\d+)\s*$/;

		# have 'Transfer-Encoding: chunked' ? read the chunks
		my $te = lc( $headers-> header('Transfer-Encoding') || '');
		return $self-> http_read_chunked($offset)
			if $self-> {chunked} = $te =~ /^chunked\s*$/i;
	
		# just read as much as possible then
		return $self-> http_tail;
	}}}}}
}

# read sequence of TE chunks
sub http_read_chunked
{
	my ( $self, $offset) = @_;

	my ( @frame, @ctx);

	# read chunk size
	pos( $self-> {buf} ) = $offset;
	context @ctx = $self-> http_read( qr/\G[\da-f]+\r?\n/i);
	tail {
		# save this lambda frame
		@frame = this_frame;
		# got error
		my $line = shift;
		return undef, shift unless defined $line;

		# advance
		$offset += length($line);
		$line =~ s/\r?\n//;
		my $size = hex $line;
		return 1 unless $size;

	# read the chunk itself
	context $self-> http_read( $size);
	tail {
		return undef, shift unless shift;
		$offset += $size + 2; # 2 for CRLF
		pos( $self-> {buf} ) = $offset;
		context @ctx;
		again( @frame);
	}};
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

=head1 BUGS

Non-blocking connects, and hence the module, don't work on win32 on perl5.8.X
due to under-implementation in ext/IO.xs .  They do work on 5.10 however. 

=head1 SEE ALSO

L<IO::Lambda>, L<HTTP::Request>, L<HTTP::Response>

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
