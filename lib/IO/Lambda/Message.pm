# $Id: Message.pm,v 1.7 2008/11/05 15:04:08 dk Exp $

use strict;
use warnings;

package IO::Lambda::Message;

our $CRLF  = "\x0a";
our @EXPORT_OK = qw(message);
our $DEBUG = $IO::Lambda::DEBUG{message} || 0;

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

		my $msg = sprintf("%08x",length($_[0])) . $CRLF . $_[0] . $CRLF;
		warn _d($self), "msg > $msg\n" if $DEBUG > 2;
	context 
		writebuf($self-> {writer}), $self-> {w},
		\ $msg, $deadline;
	tail {
		my ( $result, $error) = @_;
		return ( undef, $error) if defined $error;

	context 
		readbuf($self-> {reader}), $self-> {r}, \$self-> {buf}, 9,
		$deadline;
	tail {
		my ( $size, $error) = @_;
		return ( undef, $error) if defined $error;
		$size = substr( $self-> {buf}, 0, 9, '');
		return ( undef, "protocol error: chunk size not set")
			unless $size =~ /^[a-f0-9]+$/i;

		chop $size;
		$size = length($CRLF) + hex $size;

	context
		readbuf($self-> {reader}), $self-> {r}, \$self-> {buf},
		$size, $deadline;
	tail {
		my $error = $_[1];
		return ( undef, $error) if defined $error;
		my $msg = substr( $self-> {buf}, 0, $size, '');
		chop $msg;
		warn _d($self), "msg < $msg\n" if $DEBUG > 2;
		return $msg;
	}}}}
}

# XXX new_response_handler

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

my $debug = $IO::Lambda::DEBUG{message} || 0;

sub _d { "simple_msg($_[0])" }

sub new
{
	my ( $class, $r, $w) = @_;
	my $self = bless {
		r => $r,
		w => $w,
	}, $class;
	warn "new ", _d($self) . "\n" if $debug;
	return $self;
}

sub read
{
	my $self = $_[0];

	my $size = readline($self-> {r});
	die "bad size" unless $size =~ /^[0-9a-f]+\n$/i;
	chop $size;
	$size = 1 + hex $size;

	my $buf = '';
	while ( $size > 0) {
		my $b = readline($self-> {r});
		die "can't read from socket: $!"
			unless defined $b;
		$size -= length($b);
		$buf .= $b;
	}

	chop $buf;

	warn _d($self) . ": ", length($buf), " read\n" if $debug > 1;

	return $buf;
}

sub write
{
	my ( $self, $msg) = @_;
	warn _d($self) . ": ", length($msg), " written\n" if $debug > 1;
	printf( { $self-> {w} } "%08x\x0a%s\x0a", length($msg), $msg)
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
				warn _d($self) . ": $method died $@\n" if $debug;
				$response = [0, $@];
				$self-> quit;
			} else {
				warn _d($self) . ": $method ok\n" if $debug;
				$response = [1, @r];
			}
		} else {
			warn _d($self) . ": no such method: $method\n" if $debug;
			$response = [0, 'no such method'];
		};

		( $msg, $error) = $self-> encode($response);
		if ( defined $error) {
			( $msg, $error) = $self-> encode([0, $error]);
			die $error if $error;
		}
		$self-> write($msg);
	}

	warn _d($self) . " quit\n" if $debug;
}

1;

=pod

=head1 NAME

IO::Lambda::Message - message passing queue

=head1 DESCRIPTION

The module implements a generic message passing protocol, and two generic
classes that implement the server and the client functionality. The server
code is implemented in a simple, blocking fashion, and is only capable
of simple operations. The client API is written in lambda style, where each
message sent can be asynchronously awaited for.

=head1 SYNOPSIS

    use IO::Lambda::Message qw(message);

    lambda {
       my $messenger = IO::Lambda::Message-> new( \*READER, \*WRITER);
       context $messenger-> new_message('hello world');
    tail {
       print "response1: @_, "\n";
       context $messenger, 'same thing';
    message {
       print "response2: @_, "\n";
       undef $messenger;
    }}}

=head1 Message protocol

The message passing protocol is synchronous, any message is expected to be
replied to. Messages are prepended with simple header, that is a 8-digit
hexadecimal length of the message, and 1 byte with value 0x0A (newline).
After the message another 0x0A byte is followed.

=head1 IO::Lambda::Message

The class implements a generic message passing queue, that allows to add
asynchronous messages to the queue, and wait until they are responded to.

=over

=item new $class, $reader, $writer, %options

Constructs a new object of C<IO::Lambda::Message> class, and attaches to
C<$reader> and C<$writer> file handles ( which can be the same object ).
Accepted options:

=over

=item reader :: ($fh, $buf, $cond, $deadline) -> ioresult

Custom reader, C<sysreader> by default.

=item writer :: ($fh, $buf, $length, $offset, $deadline) -> ioresult

Custom writer, C<syswriter> by default.

=item buf :: $string

If C<$reader> handle was used (or will be needed to be used) in buffered I/O,
it's buffer can be passed along to the object.

=back

=item new_message($message, $deadline = undef) :: () -> ($response, $error)

Registers a message that must be delivered no later than C<$deadline>, and
returns a lambda that will be ready when the message is responded to.
The lambda returns the response or the error.

Currently, C<$deadline> effect on message queue is in process of changing,
because whenever a protocol handler encounters an error, all unsent messages
will be cancelled (the lambdas will get the notification though), and timeout
is also, in this regard, an error.

=head2 Server-initiated messages

XXX

The default protocol doesn't allow to server to send messages on its own.
Moreover, after the last message is read, the object doesn't listen on the
reading handle at all. If you need to implement a protocol that has support for
server-initiated messages, you need to override methods C<start_queue_handler>
and C<stop_queue_handler> that are called when message handling is started, and
stopped, respectively.

If the handler that responds to messages must fail, then it must call C<cancel_queue>
so all queued lambda will get notified.

=back

=head1 SEE ALSO

L<IO::Lambda::DBI>.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
