# $Id: Message.pm,v 1.4 2008/11/04 07:51:36 dk Exp $

use strict;
use warnings;

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

our $CRLF  = "\x0d\x0a";
our @EXPORT_OK = qw(message);
our $DEBUG = $IO::Lambda::DEBUG{message};

use Carp;
use Exporter;
use IO::Lambda qw(:all :dev);

sub _d { "message(" . _o($_[0]) . ")" }

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
	
	warn "new ", _d($self) . "\n" if $DEBUG;

	return $self;	
}

sub return_message { shift; @_ }

sub new_msg_handler
{
	my $self = shift;
	
	lambda {
		my ( undef, $deadline) = @_;

		my $msg = length($_[0]) . $CRLF . $_[0] . $CRLF;
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
	}}}}
}

sub cancel_queue
{	
	my ( $self, @reason) = @_;
	return unless $self-> {queue};
	for my $q ( @{ $self-> {queue}}) {
		my ( $outer, $bind) = @_;
		$outer-> resolve( $bind);
		$outer-> terminate( @reason);
	}
	@{ $self-> {queue} } = ();
}

sub start_messenger
{
	my $self = shift;

	die "messenger already running" if $self-> {queue_handler};
	
	warn _d($self) . ": start messenger\n" if $DEBUG;

	# override transport listener
	$self-> {transport}-> set_close_on_read(0);

	$self-> {msg_handler} = $self-> new_msg_handler;
	$self-> {messenger}   = $self-> new_messenger;
	$self-> {messenger}-> reset;
	$self-> {messenger}-> start;
}

sub stop_messenger
{
	my $self = shift;
	warn _d($self) . ": stop messenger\n" if $DEBUG;
	$self-> {transport}-> set_close_on_read(1);
	undef $self-> {messenger};
	undef $self-> {msg_handler};
}

sub new_messenger
{
	my $self = shift;
	lambda {
		warn _d($self) . ": sending msg ",
			length($self-> {queue}-> [0]-> [2]), " bytes ",
			_t($self-> {queue}-> [0]-> [3]),
			"\n" if $DEBUG;
		context $self-> {msg_handler},
			$self-> {queue}-> [0]-> [2],
			$self-> {queue}-> [0]-> [3];
	tail {
		my ( $result, $error) = @_;
		if ( defined $error) {
			warn _d($self) . " > error $error\n" if $DEBUG;
			$self-> cancel_queue( undef, $error);	
			$self-> stop_messenger;
			return ( undef, $error);
		}
		
		# signal result to the outer lambda
		my ( $outer, $bind, $msg, $deadline) = @{ shift @{$self-> {queue}} };
		$outer-> resolve( $bind);
		$outer-> terminate( $self-> return_message( $result, $error));
		
		# stop if it's all
		unless ( @{$self-> {queue}}) {
			$self-> stop_messenger;
			return;
		}

		# fire up the next request
		warn _d($self) . ": sending msg ",
			length($msg), " bytes ",
			_t($deadline),
			"\n" if $DEBUG;
		context $self-> {msg_handler}, $msg, $deadline;
		again;
	}}
}

sub new_message
{
	my ( $self, $msg, $deadline) = @_;

	if ( $DEBUG) {
		warn _d($self) . " > msg", _t($deadline), " ", length($msg), " bytes\n";
		warn _d($self) . " is faulty($self->{error})\n"
			if defined $self-> {error};
	}
	
	return lambda { undef, $self-> {error} } if defined $self-> {error};
	
	# won't end until we call resolve
	my $outer = IO::Lambda-> new;
	my $bind  = $outer-> bind;
	push @{ $self-> {queue} }, [ $outer, $bind, $msg, $deadline ];

	$self-> start_messenger if 1 == @{$self-> {queue}};

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
