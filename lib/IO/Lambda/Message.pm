# $Id: Message.pm,v 1.6 2008/11/05 12:39:34 dk Exp $

use strict;
use warnings;

package IO::Lambda::Message;

our $CRLF  = "\x0d\x0a";
our @EXPORT_OK = qw(message);
our $DEBUG = $IO::Lambda::DEBUG{message};

use Carp;
use Exporter;
use IO::Lambda qw(:all :dev);

sub _d { "message(" . _o($_[0]) . ")" }

sub new
{
	my ( $class, $r, $w, %opt ) = @_;

	$opt{reader} ||= sysreader;
	$opt{writer} ||= syswriter;
	$opt{buf}    ||= '';

	croak "Invalid read handle" unless $r;
	croak "Invalid write handle" unless $w;

	my $self = bless {
		%opt,
		r     => $r,
		w     => $w,
		queue => [],
	}, $class;
	
	warn "new ", _d($self) . "\n" if $DEBUG;

	return $self;	
}

# send a single message
sub new_msg_handler
{
	my $self = shift;
	
	lambda {
		my ( undef, $deadline) = @_;

		my $msg = length($_[0]) . $CRLF . $_[0] . $CRLF;
	context 
		writebuf($self-> {writer}), $self-> {w},
		\ $msg, $deadline;
	tail {
		my ( $result, $error) = @_;
		return ( undef, $error) if defined $error;

	context 
		readbuf($self-> {reader}), $self-> {r}, \$self-> {buf},
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
		readbuf($self-> {reader}), $self-> {r}, \$self-> {buf},
		$size, $deadline;
	tail {
		my $error = $_[1];
		return ( undef, $error) if defined $error;
		my $msg = substr( $self-> {buf}, 0, $size, '');
		substr($msg, -$crlf) = '';
		return $msg;
	}}}}
}

# lambda that sends all available messages in queue
sub new_queue_handler
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
			$self-> stop_queue_handler;
			return ( undef, $error);
		}
		
		# signal result to the outer lambda
		my ( $outer, $bind, $msg, $deadline) = @{ shift @{$self-> {queue}} };
		$outer-> resolve( $bind);
		$outer-> terminate( $self-> parse( $result));
		
		# stop if it's all
		unless ( @{$self-> {queue}}) {
			$self-> stop_queue_handler;
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

sub start_queue_handler
{
	my $self = shift;

	die "queue_handler already running" if $self-> {messenger};
	
	warn _d($self) . ": start queue\n" if $DEBUG;

	$self-> {msg_handler}   = $self-> new_msg_handler;
	$self-> {queue_handler} = $self-> new_queue_handler;
	$self-> {queue_handler}-> start;
}

sub stop_queue_handler
{
	my $self = shift;
	warn _d($self) . ": stop queue\n" if $DEBUG;
	# Technically speaking, these lambdas can be resued just fine.
	# They are destroyed though because of cyclic references,
	# because otherwise $self won't go away
	undef $self-> {queue_handler};
	undef $self-> {msg_handler};
}


# register a message, return a lambda that will be finihsed as soon
# as message gets a response.
sub new_message
{
	my ( $self, $msg, $deadline) = @_;

	warn _d($self) . " > msg", _t($deadline), " ", length($msg), " bytes\n" if $DEBUG;
	
	# won't end until we call resolve
	my $outer = IO::Lambda-> new;
	my $bind  = $outer-> bind;
	push @{ $self-> {queue} }, [ $outer, $bind, $msg, $deadline ];

	$self-> start_queue_handler if 1 == @{$self-> {queue}};

	return $outer;
}

# cancel all messages, store error on all of them
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

sub parse { $_[1] }

sub message(&) { new_message(context)-> predicate( shift, \&message, 'message') }

package IO::Lambda::Message::Simple;

sub new
{
	my ( $class, $r, $w) = @_;
	bless {
		r => $r,
		w => $w,
	}, $class;
}

sub read
{
	my $self = $_[0];

	my $size = readline($self-> {r});
	die "bad size" unless $size =~ /^(\d+)([\r\n]*)$/;
	my $crlf = length($2);
	$size = $1 + $crlf;

	my $buf = '';
	while ( $size > 0) {
		my $b = readline($self-> {r});
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
	print { $self-> {w} } length($msg) . "\x0d\x0a$msg\x0d\x0a"
		or die "can't write to socket: $!"
}

sub quit { $_[0]-> {run} = 0 }

sub run
{
	my $self = $_[0];

	$self-> {run} = 1;
	$self-> {w}-> autoflush(1);

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
