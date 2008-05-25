# $Id: HTTP.pm,v 1.32 2008/05/25 12:14:22 dk Exp $
package IO::Lambda::HTTP;
use vars qw(@ISA @EXPORT_OK $DEBUG);
@ISA = qw(Exporter);
@EXPORT_OK = qw(http_request);

$DEBUG = $ENV{IO_HTTP_DEBUG};

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
	$self-> {$_} = $options{$_} for qw(async_dns conn_cache username password domain
		auth keep_alive preferred_auth);

	my %headers;
	$headers{'User-Agent'} = "perl/IO-Lambda-HTTP v$IO::Lambda::VERSION";

	if ( $self-> {keep_alive}) {
		unless ( $self-> {conn_cache}) {
			require LWP::ConnCache;
			$self-> {conn_cache} = LWP::ConnCache-> new;
		}
		unless ( $req-> protocol) {
			$req-> protocol('HTTP/1.1');
		}
		$headers{Host}         = $req-> uri-> host;
		$headers{Connection}   = 'Keep-Alive';
		$headers{'Keep-Alive'} = 300;
	}

	require IO::Lambda::DNS if $self-> {async_dns};
	
	my $h = $req-> headers;
	while ( my ($k, $v) = each %headers) {
		$h-> header($k, $v) unless defined $h-> header($k);
	}

	return $self-> handle_redirect( $req);
}

# reissue the request, if necessary, because of 30X or 401 errors
sub handle_redirect
{
	my ( $self, $req) = @_;
		
	my $was_redirected = 0;
	my $was_failed_auth = 0;

	my $auth = $self-> {auth};

	lambda {
		my $method;
		if ( $auth) {
			# create fake response for protocol initiation, -- but just once
			my $x = HTTP::Response-> new;
			$x-> headers-> header('WWW-Authenticate', split(',', $auth));
			$method = $self-> get_authenticator( $req, $x);
			undef $auth;
		}
		context $method || $self-> handle_connection( $req);
	tail   {
		# request is finished
		my $response = shift;
		return $response unless ref($response);

		if ( $response-> code =~ /^3/) {
			$was_failed_auth = 0;
			return 'too many redirects' 
				if ++$was_redirected > $self-> {max_redirect};
			
			$req-> uri( $response-> header('Location'));
			$req-> headers-> header( Host => $req-> uri-> host);

			warn "redirect to " . $req-> uri . "\n" if $DEBUG;

			this-> start; 
		} elsif ( 
			not($was_failed_auth) and 
			$response-> code eq '401' and
			defined($self-> {username}) and
			defined($self-> {password})
		) {
			$was_failed_auth++;
			$method = $self-> get_authenticator( $req, $response);
			context $method;
			return $method ? tail {
				my $r = shift;
				return $r unless $r;

				# start from beginning, from handle_connection;
				this-> start; 
			} : $response;
		} else {
			return $response;
		}
	}};
}

# if request needs authentication, and we can do anything about it, create 
# a lambda that handles the authentication
sub get_authenticator
{
	my ( $self, $req, $response) = @_;

	# supports authentication?
	my %auth;
	for my $auth ( $response-> header('WWW-Authenticate')) {
		$auth =~ s/\s.*$//;
		$auth{$auth}++;
	}

	my %preferred = defined($self-> {preferred_auth}) ? (
		ref($self-> {preferred_auth}) ? 
			%{ $self-> {preferred_auth} } :
			( $self-> {preferred_auth} => 1 )
		) : ();
	
	my @auth = sort {
			($preferred{$b} || 0) <=> ($preferred{$a} || 0)
		} grep {
			not exists($preferred{$_}) or $preferred{$_} >= 0;
		} keys %auth;

	my $compilation_errors = '';
	for my $auth ( @auth) {
		if ( $auth eq 'Basic') {
			# always
			warn "trying basic authentication\n" if $DEBUG;
			$req-> authorization_basic( $self-> {username}, $self-> {password});
			return $self-> handle_connection( $req);
		}

		eval { require "IO/Lambda/HTTP/Authen/$auth.pm" };
		$compilation_errors .= "$@\n"
			if $@ and ($@ !~ m{^Can't locate IO/Lambda/HTTP/Authen/$auth});
		next if $@;
		
		my $lambda = "IO::Lambda::HTTP::Authen::$auth"-> 
			authenticate( $self, $req, $response);
		warn "trying authentication with '$auth'\n" if $DEBUG and $lambda;
		return $lambda if $lambda;
	}
	
	# XXX Propagate compilation errors as http errors. Doubtful.
	return lambda { $compilation_errors } if length $compilation_errors;

	return undef;
}


# get scheme and eventually load module
my $got_https;
sub prepare_transport
{
	my ( $self, $req) = @_;
	my $scheme = $req-> uri-> scheme;

	unless ( defined $scheme) {
		return "bad URI: " . $req-> uri-> as_string;
	} elsif ( $scheme eq 'https') {
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

	my $sock = IO::Socket::INET-> new(
		PeerAddr => $host,
		PeerPort => $port,
		Proto    => 'tcp',
		Blocking => 0,
	);
	return $sock, ( $sock ? undef : "connect: $!");
}

# Connect to the remote, wait for protocol to finish, and
# close the connection if needed. Returns HTTP::Reponse object on success
sub handle_connection
{
	my ( $self, $req) = @_;

	# have a chance to load eventual modules early
	my $err = $self-> prepare_transport( $req);
	return lambda { $err } if defined $err;

	my ( $host, $port) = ( $req-> uri-> host, $req-> uri-> port);
	
	lambda {
		# resolve hostname
		if (
			$self-> {async_dns} and
			$host !~ /^(\d{1,3}\.){3}(\d{1,3})$/
		) {
			context $host, 
				timeout => ($self-> {deadline} || $IO::Lambda::DNS::TIMEOUT); 
			warn "resolving $host\n" if $DEBUG;
			return IO::Lambda::DNS::dns_query( sub {
				$host = shift;
				return $host unless $host =~ /^\d/; # error
				warn "resolved to $host\n" if $DEBUG;
				return this-> start; # restart the lambda with different $host
			});
		}

		delete $self-> {close_connection};
		$self-> {close_connection}++ 
			if ( $req-> header('Connection') || '') =~ /^close/i;
		
		# got cached socket?
		my ( $sock, $cached);
		my $cc = $self-> {conn_cache};

		if ( $cc) {
			$sock = $cc-> withdraw( __PACKAGE__, "$host:$port");
			if ( $sock) {
				my $err = unpack('i', getsockopt( $sock, SOL_SOCKET, SO_ERROR));
				$err ? undef $sock : $cached++;
				warn "reused socket is ".($err ? "bad" : "ok")."\n" if $DEBUG;
			}
		}

		# connect
		my $err;
		warn "connecting\n" if $DEBUG and not($sock);
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

		$self-> {socket} = $sock;
		$self-> {reader} = readbuf ( $self-> {reader});
		$self-> {writer} = $self-> {writer}-> ($cached) if $self-> {writer}; 
		$self-> {writer} = writebuf( $self-> {writer});

		context $self-> handle_request( $req);
	tail {
		my $response = shift;
		
		# put back the connection, if possible
		if ( $cc and not $self-> {close_connection}) {
			my $err = unpack('i', getsockopt( $sock, SOL_SOCKET, SO_ERROR));
			warn "deposited socket back\n" if $DEBUG and not($err);
			$cc-> deposit( __PACKAGE__, "$host:$port", $sock)
				unless $err;
		}
			
		warn "connection:close\n" if $DEBUG and $self-> {close_connection};

		delete @{$self}{qw(close_connection socket buf writer reader)};
		
		return $response;
	}}}
}

# Execute single http request over an established connection.
# Returns either HTTP::Response object, or error string
sub handle_request
{
	my ( $self, $req) = @_;
	lambda {
		$self-> {buf} = '';
		context $self-> handle_request_in_buffer( $req);
		warn "request: " . $req-> as_string . "\n" if $DEBUG;
	tail {
		my ( undef, $error) = @_; # readbuf style
		warn "response: " . ( $error ? $error : $self-> {buf}) . "\n" if $DEBUG;
		return defined($error) ? $error : $self-> parse( \ $self-> {buf} );
	}}
}

# Execute single http request over an established connection.
# Returns 2 parameters, readbuf-style, where actually only the 2nd matters,
# and signals error if defined. 2 parameters are there for readbuf() compatibility,
# so that the protocol handler can easily fall back to readbuf() itself.
sub handle_request_in_buffer
{
	my ( $self, $req) = @_;

	lambda {
		# send request
		$req = $req-> as_string;
		context 
			$self-> {writer}, 
			$self-> {socket}, \ $req, 
			undef, 0, $self-> {deadline};
	state write => tail {
		my ( $bytes_written, $error) = @_;
		return undef, $error if $error;

		context $self-> {socket}, $self-> {deadline};
	read {
		# request sent, now wait for data
		return undef, 'timeout' unless shift;
		
		# read first line
		context $self-> http_read(qr/^.*?\n/);
	state head => tail {
		my $line = shift;
		unless ( defined $line) {
			my $error = shift;
			# remote closed connection and content is single-line HTTP/1.0
			return (undef, $error) if $error ne 'eof';
			return (undef, undef);
		}

		# no headers? 
		return $self-> http_tail
			unless $line =~ /^HTTP\/[\.\d]+\s+\d{3}\s+/i;
		
		# got some headers
		context $self-> http_read( qr/^.*?\r?\n\r?\n/s);
	state body => tail {
		$line = shift;
		return undef, shift unless defined $line;

		my $headers = HTTP::Response-> parse( $line);

		# Connection: close
		my $c = lc( $headers-> header('Connection') || '');
		$self-> {close_connection} = $c =~ /^close\s*$/i;

		return $self-> http_read_body( length $line, $headers);
	}}}}}
}

# have headers, read body
sub http_read_body
{
	my ( $self, $offset, $headers) = @_;

	# have Content-Length? read that many bytes then
	my $l = $headers-> header('Content-Length');
	return $self-> http_tail( $1 + $offset )
		if defined ($l) and $l =~ /^(\d+)\s*$/;

	# have 'Transfer-Encoding: chunked' ? read the chunks
	my $te = lc( $headers-> header('Transfer-Encoding') || '');
	return $self-> http_read_chunked($offset)
		if $self-> {chunked} = $te =~ /^chunked\s*$/i;
	
	# just read as much as possible then
	return $self-> http_tail if 
		$headers-> protocol =~ /^HTTP\/(\d+\.\d+)/ and
		$1 < 1.1;
}

# read sequence of TE chunks
sub http_read_chunked
{
	my ( $self, $offset) = @_;

	my ( @frame, @ctx);

	# read chunk size
	pos( $self-> {buf} ) = $offset;
	context @ctx = $self-> http_read( qr/\G[\da-f]+\r?\n/i);
	state size => tail {
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
	state chunk => tail {
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

   lambda {
      context shift;
      http_request {
         my $result = shift;
         if ( ref($result)) {
            print "good: ", length($result-> content), " bytes\n";
         } else {
            print "bad: $result\n";
         }
      }
   }-> wait(
       HTTP::Request-> new( GET => "http://www.perl.com/")
   );

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

=item async_dns BOOLEAN

If set, hostname will be resolved with L<IO::Lambda::DNS> using asynchronous
L<Net::DNS>. Note that this method won't be able to account for non-DNS
(/etc/hosts, NIS) host names.

If unset (default), hostnames will be resolved in a blocking manner.

=item conn_cache $LWP::ConnCache = undef

Can optionally use a C<LWP::ConnCache> object to reuse connections on per-host per-port basis.
Required for NTLM authentication.
See L<LWP::ConnCache> for details.

=item auth $AUTH

Normally, a request is sent without any authentication. When 401 error is
returned, only then authentication is tried. To avoid this first stage,
knowing in advance the type of authentication will be accepted by the
remote, C<auth> can be used.

   username => 'user',
   password => 'pass',
   auth     => 'Basic',

=item keep_alive BOOLEAN

If set, all incoming requests are silently converted to use HTTP/1.1, and connections
are reused. Same as combined effect of explicitly setting

   $req-> protocol('HTTP/1.1');
   $req-> headers-> header( Host => $req-> uri-> host);
   new( $req, conn_cache => LWP::ConnCache-> new);

=item max_redirect NUM = 7

Maximum allowed redirects. If 1, no redirection attemps are made.

=item preferred_auth $AUTH|%AUTH

List of preferred authentication methods, used to choose the authentication
method in case when many are supported by the server.  When option is a single
string, the given method is tried first, and then all available methods.  When
it is a hash, its values are treated as weight factors, - the method with the
greatest factor is tried first. Negative values exclude the corresponding
methods from trying.

     # try basic and whatever else
     preferred_auth => 'Basic',

     # try basic and never ntlm
     preferred_auth => {
         Basic => 1,
	 NTLM  => -1,
     },

Note that the current implementation doesn't provide re-trying of
authentication if either a method or username/password combination fails.
When at least one method was declared by the remote as supported, and was
tried and failed, no further retries will be made.

=item timeout SECONDS = undef

Maximum allowed time the request can take. If undef, no timeouts occur.

=back

=head1 BUGS

Non-blocking connects, and hence the module, don't work on win32 on perl5.8.X
due to under-implementation in ext/IO.xs .  They do work on 5.10 however. 

=head1 SEE ALSO

L<IO::Lambda>, L<HTTP::Request>, L<HTTP::Response>

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
