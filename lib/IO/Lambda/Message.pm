# $Id: Message.pm,v 1.1 2008/11/03 14:55:10 dk Exp $

use strict;
use warnings;

# XXX timeouts; error effects on non-executed lambdas; 
package IO::Lambda::Message::Storable;

use Storable qw(freeze thaw);

sub encode
{
	my $self = $_[0];
	my $msg;
	eval { $msg = freeze( $_[1] ) };
	return $@ ? ( undef, $@) : $msg;
}

sub decode 
{
	my $self = $_[0];
	my $msg;
	eval { $msg = thaw( $_[1] ); };
	return $@ ? ( undef, $@) : $msg;
}


package IO::Lambda::Message;

use base qw(IO::Lambda::Message::Storable);

our $DEBUG = $ENV{IO_MESSAGE_DEBUG};
our $CRLF  = "\x0d\x0a";
our @EXPORT_OK = qw(message);

use Carp;
use Exporter;
use IO::Lambda qw(:all);

sub new
{
	my ( $class, $transport, %opt ) = @_;

	$opt{reader} ||= sysreader;
	$opt{writer} ||= syswriter;
	$opt{buf}    ||= '';

	my $h;
	if ( $transport-> can('socket')) {
		$h = $transport-> socket;
	} else {
		croak "Invalid transport $transport: must support ::socket";
	}
	croak "Invalid transport $transport: no socket"
		unless $h;
	croak "Invalid transport $transport: must support ::set_close_on_read"
		unless $transport-> can('set_close_on_read');
	croak "Invalid transport $transport: must support ::close"
		unless $transport-> can('close');

	my $self = bless {
		%opt,
		handle    => $h,
		queue     => [],
		transport => $transport,
	}, $class;

	return $self;	
}

sub handle_message
{
	my ( $self, undef, $deadline) = @_;
	return ( undef, $self-> {error}) if defined $self-> {error};

	my $msg = length($_[1]) . $CRLF . $_[1] . $CRLF;
	context 
		writebuf($self-> {writer}), $self-> {handle},
		\ $msg, $deadline;
	tail {
		my ( $result, $error) = @_;
		return ( undef, $error) if defined $error;

	context 
		readbuf($self-> {reader}), $self-> {handle}, \$self-> {buf},
		qr/^[^\n\r]*\r?\n/,
		$deadline;
	tail {
		my ( $size, $error) = @_;
		return ( undef, $error) if defined $error;
		return ( undef, "protocol error: chunk size not set")
			unless $size =~ /^(\d+)([\r\n]+)$/;

		substr( $self-> {buf}, 0, length($size), '');
		my $crlf = length($2);
		$size = $1 + $crlf;

	context
		readbuf($self-> {reader}), $self-> {handle}, \$self-> {buf},
		$size, $deadline;
	tail {
		my $error = $_[1];
		return ( undef, $error) if defined $error;
		my $msg = substr( $self-> {buf}, 0, $size, '');
		substr($msg, -$crlf) = '';
		return $msg;
	}}}
}

sub return_message { shift; @_ }

sub wait_and_dequeue
{
	my ( $self, $q) = @_;
	context $q;
	tail {
		my ( $result, $error) = @_;
		shift @{$self-> {queue}};
		if ( defined $error) {
			# don't allow new lambdas, and kill the old ones
			$self-> {error} = $error;
		} else {
			$self-> {transport}-> set_close_on_read(1) unless @{$self-> {queue}};
		}
		return $self-> return_message( $result, $error);
	}
}

sub new_message
{
	my ( $self, $msg, $deadline) = @_;
	
	return lambda { undef, $self-> {error} } if defined $self-> {error};
		
	$self-> {transport}-> set_close_on_read(0) unless @{$self-> {queue}};

	my $inner = lambda {
		my ( $result, $error) = $self-> handle_message( $msg, $deadline);
		$self-> {transport}-> close if $error;
		return ( $result, $error);
	};

	my @t = ( this, context );
	
	my $outer = IO::Lambda-> new;
	this($outer);

	if ( @{$self-> {queue}}) {
		context $self-> {queue}-> [-1];
		tail { $self-> wait_and_dequeue($inner) }
	} else {
		$self-> wait_and_dequeue($inner);
	}
	
	this(@t);

	push @{$self-> {queue}}, $inner;

	return $outer;
}

sub message(&) { new_message(context)-> predicate( shift, \&message, 'message') }

sub worker
{
	my ( $socket, $class, @param) = @_;

	my $worker = bless {
		socket => $socket,
		param  => \@param,
	}, $class;

	$worker-> handle;
}

package IO::Lambda::Message::Simple;

use base qw(IO::Lambda::Message::Storable);

sub socket { $_[0]-> {socket} }

sub read
{
	my $self = $_[0];

	my $size = readline($self-> {socket});
	die "bad size" unless $size =~ /^(\d+)([\r\n]*)$/;
	my $crlf = length($2);
	$size = $1 + $crlf;

	my $buf = '';
	while ( $size > 0) {
		my $b = readline($self-> {socket});
		die "can't read from socket: $!"
			unless defined $b;
		$size -= length($b);
		$buf .= $b;
	}

	substr( $buf, -$crlf) = '';

	return $buf;
}

sub write
{
	my ( $self, $msg) = @_;
	print { $self-> {socket} } length($msg) . "\x0d\x0a$msg\x0d\x0a"
		or die "can't write to socket: $!"
}

sub quit { $_[0]-> {run} = 0 }

sub handle
{
	my $self = $_[0];

	$self-> {run} = 1;
	$self-> {socket}-> autoflush(1);

	while ( $self-> {run} ) {
		my ( $msg, $error) = $self-> decode( $self-> read);
		die "bad message: $error" if defined $error;
		die "bad message" unless 
			$msg and ref($msg) and ref($msg) eq 'ARRAY' and @$msg > 0;

		my $method = shift @$msg;

		my $response;

		if ( $self-> can($method)) {
			my $wantarray = shift @$msg;
			my @r;
			eval {
				if ( $wantarray) {
					@r    = $self-> $method(@$msg);
				} else {
					$r[0] = $self-> $method(@$msg);
				}
			};
			if ( $@) {
				$response = [0, $@];
				$self-> quit;
			} else {
				$response = [1, @r];
			}
		} else {
			$response = [0, 'no such method'];
		};

		( $msg, $error) = $self-> encode($response);
		if ( defined $error) {
			( $msg, $error) = $self-> encode([0, $error]);
			die $error if $error;
		}

		$self-> write($msg);
	}
}

1;
