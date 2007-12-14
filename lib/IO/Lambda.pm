# $Id: Lambda.pm,v 1.9 2007/12/14 20:47:49 dk Exp $

package IO::Lambda;

use Carp;
use strict;
use warnings;
use Exporter;
use Scalar::Util qw(weaken);
use vars qw(
	$LOOP %EVENTS @OBJECTS
	$VERSION @ISA
	@EXPORT_OK %EXPORT_TAGS @EXPORT_CONSTANTS @EXPORT_CLIENT
	$THIS @CONTEXT $METHOD $CALLBACK
	$DEBUG
);
$VERSION     = 0.03;
@ISA         = qw(Exporter);
@EXPORT_CONSTANTS = qw(
	IO_READ IO_WRITE IO_EXCEPTION 
	WATCH_OBJ WATCH_DEADLINE WATCH_LAMBDA WATCH_CALLBACK
	WATCH_IO_HANDLE WATCH_IO_FLAGS
);
@EXPORT_CLIENT = qw(
	this context lambda restart again
	read write sleep tail
);
@EXPORT_OK   = (@EXPORT_CLIENT, @EXPORT_CONSTANTS);
%EXPORT_TAGS = ( all => \@EXPORT_CLIENT, constants => \@EXPORT_CONSTANTS );
$DEBUG = $ENV{IO_LAMBDA_DEBUG};

use constant IO_READ              => 4;
use constant IO_WRITE             => 2;
use constant IO_EXCEPTION         => 1;

use constant WATCH_OBJ            => 0;
use constant WATCH_DEADLINE       => 1;
use constant WATCH_LAMBDA         => 1;
use constant WATCH_CALLBACK       => 2;

use constant WATCH_IO_HANDLE      => 3;
use constant WATCH_IO_FLAGS       => 4;

sub new
{
	IO::Lambda::Loop-> new unless $LOOP;
	my $self = bless {
		in      => [],    # events we wait for 
		last    => [],    # result of the last state
		stopped => 0,     # initial state
		start   => $_[1], # kick-start coderef
	}, $_[0];
	push @OBJECTS, $self;
	weaken $OBJECTS[-1];
	$self;
}

sub DESTROY
{
	my $self = $_[0];
	$self-> cancel_all_events;
	@OBJECTS = grep { defined($_) and $_ != $self } @OBJECTS;
}

sub _d     { _obj(shift), ': ', @_, "\n" }
sub _obj   { $_[0] =~ /0x([\w]+)/; "lambda($1)" }
sub _t     { defined($_[0]) ? ( "time(", $_[0]-time, ")" ) : () }
sub _ev
{
	$_[0] =~ /0x([\w]+)/;
	"event($1) ",
	(($#{$_[0]} == WATCH_IO_FLAGS) ?  (
		'fd=', 
		fileno($_[0]->[WATCH_IO_HANDLE]), 
		' ',
		( $_[0]->[WATCH_IO_FLAGS] ? (
			join('/',
				(($_[0]->[WATCH_IO_FLAGS] & IO_READ)      ? 'read'  : ()),
				(($_[0]->[WATCH_IO_FLAGS] & IO_WRITE)     ? 'write' : ()),
				(($_[0]->[WATCH_IO_FLAGS] & IO_EXCEPTION) ? 'exc'   : ()),
			)) : 
			'timeout'
		),
		' ', _t($_[0]->[WATCH_DEADLINE]),
	) : (
		ref($_[0]-> [WATCH_LAMBDA]) ?
			_obj($_[0]-> [WATCH_LAMBDA]) :
			_t($_[0]->[WATCH_DEADLINE])
	))
}
sub _msg
{
	my $self = shift;
	_d(
		$self,
		"@_ >> (",
		join(',', 
			map { 
				defined($_) ? $_ : 'undef'
			} 
			@{$self->{last}}
		),
		')'
	)
}

#
# Part I - Object interface to callback and 
# messaging interface with event loop and lambdas
#
#########################################################

# register an IO event
sub watch_io
{
	my ( $self, $flags, $handle, $deadline, $callback) = @_;

	croak "can't register events on a stopped lambda" if $self-> {stopped};
	croak "bad io flags" if 0 == ($flags & (IO_READ|IO_WRITE|IO_EXCEPTION));

	my $rec = [
		$self,
		$deadline,
		$callback,
		$handle,
		$flags,
	];
	push @{$self-> {in}}, $rec;

	warn _d( $self, "> ", _ev($rec)) if $DEBUG;

	$LOOP-> watch( $rec );
}

# register a timeout
sub watch_timer
{
	my ( $self, $deadline, $callback) = @_;

	croak "can't register events on a stopped lambda" if $self-> {stopped};
	croak "$self: time is undefined" unless defined $deadline;

	my $rec = [
		$self,
		$deadline,
		$callback,
	];
	push @{$self-> {in}}, $rec;

	warn _d( $self, "> ", _ev($rec)) if $DEBUG;

	$LOOP-> after( $rec);
}

# register a callback when another lambda exits
sub watch_lambda
{
	my ( $self, $lambda, $callback) = @_;

	croak "can't register events on a stopped lambda" if $self-> {stopped};
	croak "bad lambda" unless $lambda and $lambda->isa('IO::Lambda');

	croak "won't watch myself" if $self == $lambda;
	# XXX check cycling

	my $rec = [
		$self,
		$lambda,
		$callback,
	];
	push @{$self-> {in}}, $rec;
	push @{$EVENTS{"$lambda"}}, $rec;

	warn _d( $self, "> ", _ev($rec)) if $DEBUG;
}

# handle incoming asynchronous events
sub io_handler
{
	my ( $self, $rec) = @_;

	warn _d( $self, '< ', _ev($rec)) if $DEBUG;

	my $in = $self-> {in};
	my $nn = @$in;
	@$in = grep { $rec != $_ } @$in;
	die _d($self, 'stray ', _ev($rec))
		if $nn == @$in or $self != $rec->[WATCH_OBJ];

	@{$self->{last}} = $rec-> [WATCH_CALLBACK]-> (
		$self, 
		(($#$rec == WATCH_IO_FLAGS) ? $rec-> [WATCH_IO_FLAGS] : ()),
		@{$self->{last}}
	);
	warn $self-> _msg('io') if $DEBUG;

	unless ( @$in) {
		warn _d( $self, 'stopped') if $DEBUG;
		$self-> {stopped}++;
	}
}

# handle incoming synchronous events 
sub lambda_handler
{
	my ( $self, $rec) = @_;

	warn _d( $self, '< ', _ev($rec)) if $DEBUG;

	my $in = $self-> {in};
	my $nn = @$in;
	@$in = grep { $rec != $_ } @$in;
	die _d($self, 'stray ', _ev($rec))
		if $nn == @$in or $self != $rec->[WATCH_OBJ];

	my $lambda = $rec-> [WATCH_LAMBDA];
	die _d($self, 
		'handler called but ', _obj($lambda),
		' is not ready') unless $lambda-> {stopped};

	my $arr = $EVENTS{"$lambda"};
	@$arr = grep { $_ != $rec } @$arr;
	delete $EVENTS{"$lambda"} unless @$arr;

	@{$self->{last}} = $rec-> [WATCH_CALLBACK]-> (
		$self, 
		@{$rec-> [WATCH_LAMBDA]-> {last}}
	);
	warn $self-> _msg('tail') if $DEBUG;

	unless ( @$in) {
		warn _d( $self, 'stopped') if $DEBUG;
		$self-> {stopped} = 1;
	}
}

# Removes all avents bound to the object, notified the interested objects.
# The object becomes stopped, so no new events will be allowed to register.
sub cancel_all_events
{
	my $self = shift;

	$self-> {stopped} = 1;

	return unless @{$self-> {in}};

	$LOOP-> remove( $self) if $LOOP;
	my $arr = delete $EVENTS{$self};
	@{$self-> {in}} = (); 

	if ( $arr) {
		for my $rec ( @$arr) {
			next unless my $watcher = $rec-> [WATCH_OBJ];
			$watcher-> lambda_handler( $rec);
		}
	}
}

sub is_stopped  { $_[0]-> {stopped}  }
sub is_waiting  { not($_[0]->{stopped}) and @{$_[0]->{in}} }
sub is_passive  { not($_[0]->{stopped}) and not(@{$_[0]->{in}}) }
sub is_active   { $_[0]->{stopped} or @{$_[0]->{in}} }

# resets the state machine
sub reset
{
	my $self = shift;

	$self-> cancel_all_events;
	@{$self-> {last}} = ();
	delete $self-> {stopped};
	warn _d( $self, 'reset') if $DEBUG;
}

# starts the state machine
sub start
{
	my $self = shift;

	croak "can't start active lambda, call reset() first" if $self-> is_active;

	warn _d( $self, 'started') if $DEBUG;
	@{$self->{last}} = $self-> {start}-> ($self, @{$self->{last}})
		if $self-> {start};
	warn $self-> _msg('initial') if $DEBUG;
	
	unless ( @{$self->{in}}) {
		warn _d( $self, 'stopped') if $DEBUG;
		$self-> {stopped} = 1;
	}
}

# peek into the current state
sub peek { wantarray ? @{$_[0]->{last}} : $_[0]-> {last} }

# pass initial parameters to lambda
sub call 
{
	my $self = shift;

	croak "can't call active lambda" if $self-> is_active;

	@{$self-> {last}} = @_;
	$self;
}

# abandon all states and stop with constant message
sub terminate
{
	my ( $self, @error) = @_;

	$self-> cancel_all_events;
	$self-> {last} = \@error;
	warn $self-> _msg('terminate') if $DEBUG;
}

# synchronization

# drives all objects until all of them
# are either stopped, or in a blocking state
sub drive
{
	my $changed = 1;
	my $executed = 0;
	warn "IO::Lambda::drive --------\n" if $DEBUG;
	while ( $changed) {
		$changed = 0;

		# kickstart
		$executed++, $_-> start
			for grep { $_-> is_passive } @OBJECTS;

		# dispatch
		for my $rec ( map { @$_ } values %EVENTS) {
			next unless $rec->[WATCH_LAMBDA]-> {stopped};
			$rec->[WATCH_OBJ]-> lambda_handler( $rec);
			$changed = 1;
			$executed++;
		}
	warn "IO::Lambda::drive .........\n" if $DEBUG and $changed;
	}
	warn "IO::Lambda::drive +++++++++\n" if $DEBUG;

	return $executed;
}

# wait for all lambdas to stop
sub wait
{
	my $self = shift;
	$self-> call(@_) if $self-> is_passive;
	while ( 1) {
		my $n = drive;
		last if $self-> {stopped};
		croak "IO::Lambda: infinite loop detected" if not($n) and $LOOP-> empty;
		$LOOP-> yield;
	}
	return wantarray ? $self-> peek : $self-> peek-> [0];
}

sub wait_for_all
{
	my @objects = @_;
	while ( 1) {
		my $n = drive;
		@objects = grep { not $_-> {stopped} } @objects;
		last unless @objects;
		croak "IO::Lambda: infinite loop detected" if not($n) and $LOOP-> empty;
		$LOOP-> yield;
	}
}

# wait for at least one lambda to stop, returns those that stopped
sub wait_for_any
{
	my @objects = @_;
	$_-> step for @objects;
	while ( 1) {
		my $n = drive;
		@objects = grep { $_-> {stopped} } @objects;
		return @objects if @objects;
		croak "IO::Lambda: infinite loop detected" if not($n) and $LOOP-> empty;
		$LOOP-> yield;
	}
}

# run the event loop until no lambdas are left in blocking state
sub run
{
	while ( $LOOP) {
		drive;
		last if $LOOP-> empty;
		$LOOP-> yield;
	}
}	

#
# Part II - Procedural interface to the lambda-style pogramming
#
################################################################

sub lambda(&)
{
	my $cb  = $_[0];
	my @args;
	my $wrapper;
	my $this;
	$wrapper = sub {
		$THIS     = $this;
		@CONTEXT  = ();
		$CALLBACK = $cb;
		$METHOD   = $wrapper;
		$cb ? $cb-> (@args) : @args;
	};
	$this = __PACKAGE__-> new( sub {
		$THIS     = shift;
		@CONTEXT  = ();
		@args     = @_;
		$CALLBACK = $cb;
		$METHOD   = $wrapper;
		$cb ? $cb-> (@_) : @_;
	});
}

# restart latest state
sub again
{ 
	defined($METHOD) ? 
		$METHOD-> ( $CALLBACK ) : 
		croak "again predicate outside of a restartable call" 
}

# define context
sub this         { @_ ? ($THIS, @CONTEXT) = @_ : $THIS }
sub context      { @_ ? @CONTEXT = @_ : @CONTEXT }
sub restart      { @_ ? ( $METHOD, $CALLBACK) = @_ : ( $METHOD, $CALLBACK) }


#
# Predicates:
#

# common wrapper for declaration of handle-watching user predicates
sub add_watch
{
	my ($self, $cb, $method, $flags, $handle, $deadline, @ctx) = @_;
	$self-> watch_io(
		$flags, $handle, $deadline,
		sub {
			$THIS     = shift;
			@CONTEXT  = @ctx;
			$METHOD   = $method;
			$CALLBACK = $cb;
			$cb ? $cb-> (@_) : @_;
		}
	)
}

# io($flags,$handle,$deadline)
sub io(&)
{
	$THIS-> add_watch( 
		shift, \&watch,
		@CONTEXT[0,1,2,0,1,2]
	)
}

# read($handle,$deadline)
sub read(&)
{
	$THIS-> add_watch( 
		shift, \&read, IO_READ, 
		@CONTEXT[0,1,0,1]
	)
}

# handle($handle,$deadline)
sub write(&)
{
	$THIS-> add_watch( 
		shift, \&write, IO_WRITE, 
		@CONTEXT[0,1,0,1]
	)
}

# common wrapper for declaration of time-watching user predicates
sub add_timer
{
	my ($self, $cb, $method, $deadline, @ctx) = @_;
	$self-> watch_timer(
		$deadline,
		sub {
			$THIS     = shift;
			@CONTEXT  = @ctx;
			$METHOD   = $method;
			$CALLBACK = $cb;
			$cb ? $cb-> (@_) : @_;
		}
	)
}

# sleep($deadline)
sub sleep(&) { $THIS-> add_timer( shift, \&sleep, @CONTEXT[0,0]) }

# common wrapper for declaration of single lambda-watching user predicates
sub add_tail
{
	my ($self, $cb, $method, $lambda, @ctx) = @_;
	$self-> watch_lambda(
		$lambda,
		sub {
			$THIS     = shift;
			@CONTEXT  = @ctx;
			$METHOD   = $method;
			$CALLBACK = $cb;
			$cb ? $cb-> (@_) : @_;
		},
	);
}

# tail(@lambdas) -- wait for all lambdas to finish
sub tail(&)
{
	my $cb = $_[0];
	my @lambdas = context;
	my $n = $#lambdas;
	croak "no tails" unless @lambdas;

	my @ret;
	my $watcher = sub {
		$THIS     = shift;
		push @ret, @_;
		return if $n--;

		@CONTEXT  = @lambdas;
		$METHOD   = \&tail;
		$CALLBACK = $cb;
		$cb ? $cb-> (@ret) : @ret;
	};
	$THIS-> watch_lambda( $_, $watcher) for @lambdas;
}

package IO::Lambda::Loop;
use vars qw($DEFAULT);
use strict;
use warnings;

$DEFAULT = 'Select';
sub default { $DEFAULT = shift }

sub new
{
	return $IO::Lambda::LOOP if $IO::Lambda::LOOP;

	my ( $class, %opt) = @_;

	$opt{type} ||= $DEFAULT;
	$class .= "::$opt{type}";
	eval "use $class;";
	die $@ if $@;

	return $IO::Lambda::LOOP = $class-> new();
}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda - non-blocking I/O in lambda style

=head1 DESCRIPTION

This module is another attempt to fight the horrors of non-blocking I/O
programming. The simplicity of the sequential programming is only available
when one employs threads, coroutines, or coprocesses. Otherwise state machines
are to be built, often quite complex, which fact doesn't help the clarity of
the code. This module uses closures to achieve clarity of sequential
programming with single-process, single-thread, non-blocking I/O.

=head1 SYNOPSIS

=head2 Execution flow
    
Prerequisite
    
    use IO::Lambda qw(:all);

Create an empty IO::Lambda object

    my $q = lambda {};

Wait for it to finish

    $q-> wait;

Create lambda object and get its value

    $q = lambda { 42 };
    print $q-> wait; # will print 42

Create pipeline of two lambda objects

    $q = lambda {
        context lambda { 42 };
	tail { 1 + shift };
    };
    print $q-> wait; # will print 43

Create pipeline that waits for 2 lambdas
    
    $q = lambda {
        context lambda { 2 }, lambda { 3 };
	tail { sort @_ }; # order is not guaranteed
    };
    print $q-> wait; # will print 23

=head2 Non-blocking I/O

Given a socket, create a lambda that implements http protocol

    sub talk
    {
        my $req    = shift;
        my $socket = IO::Socket::INET-> new( $req-> host, $req-> port);

	lambda {
	    context $socket;
	    write {
	        # connected
		print $socket "GET ", $req-> uri, "\r\n\r\n";
		my $buf = '';
		read {
		    sysread $socket, $buf, 1024, length($buf) or return $buf;
		    again; # wait for reading and re-do the block
		}
	    }
	}
    }

Connect and talk to the remote

    $request = HTTP::Request-> new( GET => 'http://www.perl.com');

    my $q = talk( $request );
    print $q-> wait; # will print content of $buf

Connect two parallel connections: by explicitly waiting for each 

    $q = lambda {
        context talk($request);
	tail { print shift };
        context talk($request2);
	tail { print shift };
    };
    $q-> wait;

Connect two parallel connections: by waiting for all

    $q = lambda {
        context talk($request1), talk($request2);
	tail { print for @_ };
    };
    $q-> wait;

Teach our simple http request to redirect by wrapping talk().
talk_redirect() will have exactly the same properties as talk() does

    sub talk_redirect
    {
        my $req = shift;
	lambda {
	    context talk( $req);
	    tail {
	        my $res = HTTP::Response-> parse( shift );
		return $res unless $res-> code == 302;

		$req-> uri( $res-> uri);
	        context talk( $req);
		again;
	    }
	}
    }

=head2 Working example

    use strict;
    use IO::Lambda qw(:all);
    use IO::Socket::INET;
    my $q = lambda {
        my ( $socket, $url) = @_;
        context $socket;
        write {
            print $socket "GET $url HTTP/1.0\r\n\r\n";
            my $buf = '';
            read {
                my $n = sysread( $socket, $buf, 1024, length($buf));
		return "read error:$!" unless defined $n;
		return $buf unless $n;
                again;
            }
        }
    };
    print $q-> wait( 
        IO::Socket::INET-> new( 
            PeerAddr => 'www.perl.com', 
            PeerPort => 80 
        ),
        '/index.html'
    );

See tests and examples in directory C<eg/> for more.

=head1 API

=head2 Events and states

A lambda is a C<IO::Lambda> object, that waits for IO and timeout events, and
also events generated when other lambdas are finished. On each event a callback
bound to the event is executed. The result of this code is saved, and passed on
the next callback.

A lambda can be in one of three modes: passive, waiting, and stopped. A lambda
that is just created, or was later reset with C<reset> call, is in passive state.
When it will be started, the only callback associated with the lambda will be executed:

    $q = lambda { print "hello world!\n" };
    # here not printed anything yet

A lambda is never started explicitly; C<wait> will start passive lambdas, and will
wait for the caller lambda to finish. A lambda is finished when there are no more
events to listen to. The example lambda above will be finished as soon as it is started.

Lambda can listen to events by calling predicates, that internally subscribe the
lambda object to either corresponding file handles, timers, or other lambdas. There
are only those three types of events that basically constitute everything needed for
building state machive driven by non-blocking IO. Parameters to be passed to predicates
are stored on stack with C<context> call; for example, to listen for when a file handle
becomes readable, such code is used:

    $q = lambda {
        context \*SOCKET;
	read { print "I'm readable!\n"; }
	# here is nothing printed yet
    };
    # and here is nothing printed yet

This lambda, when started, will switch to the waiting state, - waiting for the socket.
After the callback associated with C<read> will be called, only then the lambda will finish.

Of course, new events can be created inside all callbacks, on each state. This way,
lambdas resemble dynamic programming, when the state machine is not given in advance,
but is built as soon as code that gets there is executed.

The events can be created either by explicitly calling predicates, or restarting the
last predicate with C<again> call. For example, code

     read { int(rand 2) ? 0 : again }

will be impossible to tell how many times was called.

=head2 Context

Each lambda executes in its own, private context. The context here means that all predicates
register callbacks on an implicitly given lambda object, and retain the parameters passed to
them further on. That helps for example to rely on the fact that context is preserved in
a series on IO calls,

    context \*SOCKET;
    write {
    read {
    }}

which is actually a shorter form for

    context \*SOCKET;
    write {
    context \*SOCKET; # <-- context here is retained from one frame up
    read {
    }}

Where the parameters to predicates are stored in context, the current lambda object
is also implicitly stored in C<this> property. The above code is actually is

    my $self = this;
    context \*SOCKET;
    write {
    this $self;      # <-- object reference is retained here
    context \*SOCKET;
    read {
    }}

C<this> can be used if more than one lambda is need to be accessed. In which case,

    this $object;
    context @context;

is the same as

    this $object, @context;

which means that explicitly setting C<this> will always clear the context.

=head2 Time

Timers and I/O timeouts are given not in the timeout values, as it usually
is in event libraries, but as deadline in (fractional) seconds. This,
strange at first sight decision, actually helps a lot when a total execution
time is to be tracked. For example, the following code reads as many bytes from
a socket within 5 seconds:

   lambda {
       my $buf = '';
       context $socket, time + 5;
       read {
           if ( shift ) {
	       return again if sysread $socket, $buf, 1024, length($buf);
	   } else {
	       print "oops! a timeout\n";
	   }
	   $buf;
       }
   };

Internally, timers use C<Time::HiRes::time> that gives fractional seconds.
However, this is not required for the caller, in which case timeouts will
be simply rounded to integer second.

=head2 Predicates

All predicates read parameters from the context. The only parameter passed
with perl call, is a callback. Predicates can be called without the callback,
in which case, they will simply pass further data that otherwise would be
passed as C<@_> to the callback. So, a predicate can be called either as

    read { .. code ... }

or 

    &read; # no callback

=over

=item read($filehandle, $deadline = undef)

Executes either when C<$filehandle> becomes readable, or after C<$deadline>.
Passes one argument, which is either TRUE if the handle is readable, or FALSE
if time is expired. If C<deadline> is C<undef>, no timeout is registered, i.e.
will never execute with FALSE.

=item write($filehandle, $deadline = undef)

Exaclty same as C<read>, but executes when C<$filehandle> becomes writable.

=item io($flags, $filehandle, $deadline = undef)

Executes either when C<$filehandle> satisfies the condition passed in C<$flags>,
or after C<$deadline>. C<$flags> is a combination of three integer constants,
C<IO_READ>, C<IO_WRITE>, and C<IO_EXCEPTION>, that are imported with

   use IO::Lambda qw(:constants);

Passes one argument, which is either a combination of the same C<IO_XXX> flags,
that show what conditions the handle satisfies, or 0 if time is expired. If
C<deadline> is C<undef>, no timeout is registered, i.e.  will never execute
with 0.

=item sleep($deadline)

Executes after C<$deadline>. C<$deadline> cannot be C<undef>.

=item tail(@lambdas)

Executes when all objects in C<@lambdas> are finished, passes the
collected results of the lambdas to the callback. The result order
is not guaranteed.

=back

=head1 SEE ALSO

L<Coro>, L<threads>, L<Event::Lib>.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2007 capmon ApS. All rights reserved.

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
