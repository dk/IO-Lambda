# $Id: Lambda.pm,v 1.22 2008/01/09 11:50:46 dk Exp $

package IO::Lambda;

use Carp;
use strict;
use warnings;
use Exporter;
use Scalar::Util qw(weaken);
use vars qw(
	$LOOP %EVENTS @OBJECTS @LOOPS
	$VERSION @ISA
	@EXPORT_OK %EXPORT_TAGS @EXPORT_CONSTANTS @EXPORT_CLIENT
	$THIS @CONTEXT $METHOD $CALLBACK
	$DEBUG
);
$VERSION     = 0.07;
@ISA         = qw(Exporter);
@EXPORT_CONSTANTS = qw(
	IO_READ IO_WRITE IO_EXCEPTION 
	WATCH_OBJ WATCH_DEADLINE WATCH_LAMBDA WATCH_CALLBACK
	WATCH_IO_HANDLE WATCH_IO_FLAGS
);
@EXPORT_CLIENT = qw(
	this context lambda restart again
	io read getline write sleep tail
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
	$_-> remove($self) for @LOOPS;
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

	return if delete $self-> {restarted_hack};
	
	unless ( @{$self->{in}}) {
		warn _d( $self, 'stopped') if $DEBUG;
		$self-> {stopped} = 1;
	}
}

# peek into the current state
sub peek { wantarray ? @{$_[0]->{last}} : $_[0]-> {last}-> [0] }

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
		$_-> yield for @LOOPS;
		$LOOP-> yield;
	}
	return $self-> peek;
}

sub wait_for_all
{
	my @objects = @_;
	return unless @objects;
	my @ret;
	while ( 1) {
		my $n = drive;
		push @ret, map { $_-> peek } grep { $_-> {stopped} } @objects;
		@objects = grep { not $_-> {stopped} } @objects;
		last unless @objects;
		$_-> yield for @LOOPS;
		$LOOP-> yield;
	}
	return @ret;
}

# wait for at least one lambda to stop, returns those that stopped
sub wait_for_any
{
	my @objects = @_;
	return unless @objects;
	$_-> step for @objects;
	while ( 1) {
		my $n = drive;
		@objects = grep { $_-> {stopped} } @objects;
		return @objects if @objects;
		$_-> yield for @LOOPS;
		$LOOP-> yield;
	}
}

# run the event loop until no lambdas are left in blocking state
sub run
{
	while ( $LOOP) {
		drive;
		$_-> yield for @LOOPS;
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
	__PACKAGE__-> new( sub {
		$THIS     = shift;
		@CONTEXT  = ();
		$CALLBACK = $cb;
		$METHOD   = \&_lambda_restart;
		$cb ? $cb-> (@_) : @_;
	});
}
sub _lambda_restart
{
	$THIS-> cancel_all_events;
	delete $THIS-> {stopped};
	$THIS-> {restarted_hack} = 1;
}

# restart latest state
sub again
{ 
	defined($METHOD) ? 
		$METHOD-> ( $CALLBACK) : 
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

# getline($handle,$buf_ptr,$deadline)
sub getline(&)
{
	my ( $cb, $fh, $buf, $deadline) = ( shift, context);

	my $bufsize;
	croak "getline: buffer is required" unless $buf;
	$$buf = '' unless defined $$buf;

	# each time we're called, create a new lambda
	# depending on whether there is something alredy in the buffer or not
	my $lambda = ( $$buf =~ s/^([^\n]*\n)//) ?
		# create lambda with constant value
		IO::Lambda-> new-> call($1) : 
		# create lambda that will read from handle
		lambda {
			context $fh, $deadline;
			IO::Lambda::read {
				# timeout? return nothing
				$@ = 'timeout', return undef unless shift;
				my $n = sysread $fh, $$buf, 1024, length($$buf);
				# error? return undef
				$@ = $!, return undef unless defined $n;
				# closed handle?
				unless ( $n) {
					$@ = $!, return undef unless length $$buf;
					# return whatever left in the buffer
					my $x = $$buf;
					$$buf = '';
					return $x;
				};
				# got line? return it
				return $1 if $$buf =~ s/^([^\n]*\n)//;
				# otherwise, just wait for more data
				again;
			}
		};
	
	# register the caller to wait for the lambda
	this-> add_tail(
		$cb,
		\&getline,
		$lambda,
		$fh, $buf, $deadline
	);
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

#
# Part III - Developer API for custom condvars and event loops
#
################################################################

# register condvar listener
sub bind
{
	my $self = shift;

	# create new condition
	croak "can't register events on a stopped lambda" if $self-> {stopped};

	my $rec = [ $self, @_ ];
	push @{$self-> {in}}, $rec;

	return $rec;
}

# stop listening on a condvar
sub resolve
{
	my ( $self, $rec) = @_;

	my $in = $self-> {in};
	my $nn = @$in;
	@$in = grep { $rec != $_ } @$in;
	die _d($self, "stray condvar event $rec (@$rec)")
		if $nn == @$in or $self != $rec->[WATCH_OBJ];

	undef $rec-> [WATCH_OBJ]; # unneeded references

	unless ( @$in) {
		warn _d( $self, 'stopped') if $DEBUG;
		$self-> {stopped} = 1;
	}
}

sub add_loop     { push @LOOPS, shift }
sub remove_loop  { @LOOPS = grep { $_ != $_[0] } @LOOPS }

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

=head2 Basics

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

A lambda is an C<IO::Lambda> object, that waits for IO and timeout events, and
for events generated when other lambdas are finished. On each such event a
callback is executed. The result of the execution is saved, and passed on to the
next callback, when the next event arrives.

Life cycle of a lambda goes through three modes: passive, waiting, and stopped.
A lambda that is just created, or was later reset with C<reset> call, is in
passive state.  When the lambda is started, the only callback associated with the
lambda will be executed:

    $q = lambda { print "hello world!\n" };
    # not printed anything yet
    $q-> wait; # <- here will

Lambdas are never started explicitly; C<wait> will start passive lambdas, and
will wait for the caller lambda to finish. Lambda is finished when there are no
more events to listen to. The example lambda above will finish right after
C<print> statement.

Lambda can listen to events by calling predicates, that internally subscribe
the lambda object to corresponding file handles, timers, and other lambdas.
There are only those three types of events that basically constitute everything
needed for building a state machive driven by external events, in particular,
by non-blocking I/O. Parameters passed to predicates with explicit C<context>
call, not by perl subroutine call convention. In the example below,
lambda watches for file handle readability:

    $q = lambda {
        context \*SOCKET;
	read { print "I'm readable!\n"; }
	# here is nothing printed yet
    };
    # and here is nothing printed yet

Such lambda, when started, will switch to the waiting state, - will be waiting
for the socket. The lambda will finish only after the callback associated with
C<read> predicate is called.

Of course, new events can be created inside all callbacks, on each state. This
style resembles a dynamic programming of sorts, when the state machine is not
hard-coded in advance, but is built as soon as code that gets there is executed.

The events can be created either by explicitly calling predicates, or by
restarting the last predicate with C<again> call. For example, code

     read { int(rand 2) ? print 1 : again }

will print undeterminable number of ones.

=head2 Contexts

Each lambda callback (further on, merely lambda) executes in its own, private
context. The context here means that all predicates register callbacks on an
implicitly given lambda object, and keep the passed parameters on the context
stack. The fact that context is preserved between states, help build terser
code with series of IO calls:

    context \*SOCKET;
    write {
    read {
    }}

is actually a shorter form for

    context \*SOCKET;
    write {
    context \*SOCKET; # <-- context here is retained from one frame up
    read {
    }}

And as context is kept, the current lambda object is also, but in C<this>
property. The code above is actually

    my $self = this;
    context \*SOCKET;
    write {
    this $self;      # <-- object reference is retained here
    context \*SOCKET;
    read {
    }}

C<this> can be used if more than one lambda needs to be accessed. In which case,

    this $object;
    context @context;

is the same as

    this $object, @context;

which means that explicitly setting C<this> will always clear the context.

=head2 Data and execution flow

Lambda is initially called with arguments passed from outside. These arguments
can be stored using C<call> method; C<wait> also issues C<call> internally,
thus replacing any previous data stored by C<call>. Inside the lambda
these arguments are available as C<@_>.

Whatever is returned by a predicate callback (including C<lambda> predicate),
will be passed as C<@_> to the next callback, or to outside, if the lambda is
finished. The result of a finished lambda is available by C<peek> method, that
returns either all array of data available in the array context, or first item
in the array otherwise. C<wait> returns the same data as C<peek> does.

When more than one lambda watches for another lambda, the latter will get its
last callback results passed to all the watchers. However, when a lambda
creates more than one state that derive from the current state, a forking
behaviour of sorts, the latest stored results will get overwritten by the first
executed callback, so constructions like

    read  { 1 + shift };
    write { 2 + shift };
    ...
    wait(0)

will eventually return 3, but whether it will be 1+2 or 2+1, is not known.

C<wait> is not the only function that synchronizes input and output data.
C<wait_for_all> method waits for all lambdas, including the caller, to finish.
It returns collected results of all the objects in a single list.
C<wait_for_any> method waits for at least one lambda, from the list of passed
lambdas (again, including the caller), to finish. It returns list of finished
objects as soon as possible.

=head2 Time

Timers and I/O timeouts are given not in the timeout values, as it usually is
in event libraries, but as deadlines in (fractional) seconds since epoch. This
decision, strange at first sight, actually helps a lot when total execution
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

Rewriting it with C<read> semantics that accepts time as timeout instead, is
left as an exercise to the reader.

Internally, timers use C<Time::HiRes::time> that gives fractional number of
seconds. This however is not required for the caller, in which case timeouts
will simply be less precise, and will jitter plus-minus half a second.

=head2 Predicates

All predicates receive their parameters from the context stack, or simply the
context. The only parameter passed to them by using perl call, is a callback
itself.  Predicates can also be called without a callback, in which case, they
will simply pass further data that otherwise would be passed as C<@_> to the
callback. Thus, a predicate can be called either as

    read { .. code ... }

or 

    &read; # no callback

Predicates can either be used after explicit exporting of them by

   use IO::Lambda qw(:all);
   lambda { ... }

or by using the package syntax,

   use IO::Lambda;
   IO::Lambda::lambda { ... };

=over

=item lambda()

Creates a new C<IO::Lambda> object.

=item read($filehandle, $deadline = undef)

Executes either when C<$filehandle> becomes readable, or after C<$deadline>.
Passes one argument, which is either TRUE if the handle is readable, or FALSE
if time is expired. If C<deadline> is C<undef>, then no timeout is registered,
that means that it will never execute with FALSE.

=item getline($filehandle, $$buffer, $deadline = undef)

Executes either when a line can be read from C<$filehandle>, or after
C<$deadline> if the latter is defined. On success, returns the line read.
Otherwise, returns undef, and stores the error message in C<$@>, which can
either C<timeout>, C<eof>, or C<$!> string value.

Note: buffer must be shared for all C<$filehandle> operations.

This predicate is a higher-level predicate, that operates on predicates itself.
You're welcome to study its source code.

=item write($filehandle, $deadline = undef)

Exaclty same as C<read>, but executes when C<$filehandle> becomes writable.

=item io($flags, $filehandle, $deadline = undef)

Executes either when C<$filehandle> satisfies any of the condition C<$flags>,
or after C<$deadline>. C<$flags> is a combination of three integer constants,
C<IO_READ>, C<IO_WRITE>, and C<IO_EXCEPTION>, that are imported with

   use IO::Lambda qw(:constants);

Passes one argument, which is either a combination of the same C<IO_XXX> flags,
that report which conditions the handle satisfied, or 0 if time is expired. If
C<deadline> is C<undef>, no timeout is registered, i.e. will never return 0.

=item sleep($deadline)

Executes after C<$deadline>. C<$deadline> cannot be C<undef>.

=item tail(@lambdas)

Executes when all objects in C<@lambdas> are finished, returns the collected,
unordered results of the objects.

=item again()

Restarts the current state with the current context. All the predicates above,
including C<lambda>, are restartable. The code

   context $obj1;
   tail {
       return if $null++;
       context $obj2;
       again;
   };

is thus equivalent to

   context $obj1;
   tail {
       context $obj2;
       &tail;
   };

C<again> passes the current context to the predicate.

=item context @ctx

If called with no parameters, returns the current context, otherwise
replaces the current context with C<@ctx>. It is thus not possible 
(not that it is practical anyway) to clear the context with this call.
If really needed, use C<this(this)> syntax.

=item this $this, @ctx

If called with no parameters, returns the current lambda.
Otherwise, replaces both the current lambda and the current context.
Can be useful either when juggling with several lambdas, or as a
conveniency over C<my> variables, for example,

    this lambda { ... };
    this-> wait;

instead of

    my $q = lambda { ... };
    $q-> wait;

=item restart $method, $callback

The predicate used for declaration of user-defined restartable predicates
(it is not a requirement for a predicate to be restartable though).

This predicate is mostly for internal use, and it is not really decided yet 
if it will stay. See the module source code for details of the use.

=back

=head2 Object API

This section lists methods of C<IO::Lambda> class. Note that all lambda-style
functionality is also available for object-style programming by design.
Together with the fact that lambda syntax is not exported by default, it thus
leaves a place for possible implementations of independent syntaxes, either with
or without lambdas, on top of the object API, without accessing the internals.

=over

=item new

Creates new C<IO::Lambda> object in passive state.

=item watch_io($flags, $handle, $deadline, $callback)

Registers an IO event listener that will call C<$callback> either after
C<$handle> will satisfy condition of C<$flags> ( a combination of IO_READ,
IO_WRITE, and IO_EXCEPTION bits), or after C<$deadline> time is passed. If
C<$deadline> is undef, will watch for the file handle indefinitely.

The callback will be called with first parameter as integer set of IO_XXX
flags, or 0 if timed out. Other parameters, as with the other callbacks, will
be passed the result of the last called callback. The result of the callback
will be stored and passed on to the next callback.

=item watch_timer($deadline, $callback)

Registers a timer listener that will call C<$callback> after
C<$deadline> time.

=item watch_lambda($lambda, $callback)

Registers a listener that will call C<$callback> after C<$lambda>,
a C<IO::Lambda> object is finished. If C<$lambda> is in passive state,
it will be started first.

=item is_stopped

Reports whether lambda is stopped or not.

=item is_waiting

Reports whether lambda has any registered callbacks left or not.

=item is_passive

Reports if lambda wasn't run yet, -- either after C<new>
or C<reset>.

=item is_active

Reports if lambda was run.

=item reset

Cancels all watchers and switches the lambda to the passive state. 
If there are any lambdas that watch for this object, these will
be called first.

=item peek

At any given time, returns stored data that are either passed
in by C<call> if the lambda is in the passive state, or stored result
of execution of the latest callback.

=item call @args

Stores C<@args> internally, to be passed on to the first callback. Only
works in passive state, croaks otherwise. If called multiple times,
arguments from the previous calls are overwritten.

=item terminate @args

Cancels all watchers and resets lambda to the stopped state.  If there are any
lambdas that watch for this object, these will be called first. C<@args> will
be stored and available for later calls by C<peek>.

=item wait @args

Waits for the caller lambda to finish, returns the result of C<peek>.
If the object was in passive state, calls C<call(@args)>, otherwise
C<@args> are not used.

=item wait_for_all @lambdas

Waits for caller lambda and C<@lambdas> to finish. Returns
collection of C<peek> results for all objects. The return results
are unordered.

=item wait_for_any @lambdas

Waits for at least one lambda from list of caller lambda and C<@lambdas> to
finish.  Returns list of finished objects.

=item run

Enters the event loop and doesn't exit until there are no registered events.
Can be also called as package method.

=item bind @args

Creates an event record that contains the lambda and C<@args>, and returns it.
The lambda won't finish until this event is returned with C<resolve>.

C<bind> can be called several times on a single lambda; each event requires
individual C<resolve>.

=item resolve $event

Removes C<$event> from the internal waiting list. If lambda has no more
events to wait, notifies eventual lambdas that wait to the objects, and
the stops.

Note that C<resolve> doesn't call provide any means to call associated
callbacks, which is intentional.

=back

=head1 SEE ALSO

L<Coro>, L<threads>, L<POE>.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2007 capmon ApS. All rights reserved.

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
