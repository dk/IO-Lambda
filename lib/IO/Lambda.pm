# $Id: Lambda.pm,v 1.44 2008/05/25 06:50:30 dk Exp $

package IO::Lambda;

use Carp;
use strict;
use warnings;
use Exporter;
use Time::HiRes qw(time);
use vars qw(
	$LOOP %EVENTS @LOOPS
	$VERSION @ISA
	@EXPORT_OK %EXPORT_TAGS @EXPORT_CONSTANTS @EXPORT_LAMBDA @EXPORT_STREAM
	$THIS @CONTEXT $METHOD $CALLBACK
	$DEBUG
);
$VERSION     = '0.18';
@ISA         = qw(Exporter);
@EXPORT_CONSTANTS = qw(
	IO_READ IO_WRITE IO_EXCEPTION 
	WATCH_OBJ WATCH_DEADLINE WATCH_LAMBDA WATCH_CALLBACK
	WATCH_IO_HANDLE WATCH_IO_FLAGS
);
@EXPORT_STREAM = qw(
	sysreader syswriter getline readbuf writebuf
);
@EXPORT_LAMBDA = qw(
	this context lambda this_frame again
	io read write sleep tail tails
);
@EXPORT_OK   = (@EXPORT_LAMBDA, @EXPORT_CONSTANTS, @EXPORT_STREAM, qw(state));
%EXPORT_TAGS = (
	lambda    => \@EXPORT_LAMBDA, 
	stream    => \@EXPORT_STREAM, 
	constants => \@EXPORT_CONSTANTS,
	all       => \@EXPORT_OK,
);
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
	return bless {
		in      => [],    # events we wait for 
		last    => [],    # result of the last state
		stopped => 0,     # initial state
		start   => $_[1], # kick-start coderef
	}, $_[0];
}

sub DESTROY
{
	my $self = $_[0];
	$self-> cancel_all_events;
}

my  $_doffs = 0;
sub _d_in  { $_doffs++ }
sub _d_out { $_doffs-- if $_doffs }
sub _d     { ('  ' x $_doffs), _obj(shift), ': ', @_, "\n" }
sub _obj   { $_[0] =~ /0x([\w]+)/; "lambda($1)." . ( $_[0]->{caller} || '()' ) }
sub _t     { defined($_[0]) ? ( "time(", $_[0]-time(), ")" ) : () }
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

	$deadline += time if defined($deadline) and $deadline < 1_000_000_000;
	
	return $self-> override_handler( 'watch_io', $flags, $handle, $deadline, $callback)
		if $self-> {override};

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

	return $rec;
}

# register a timeout
sub watch_timer
{
	my ( $self, $deadline, $callback) = @_;

	croak "can't register events on a stopped lambda" if $self-> {stopped};
	croak "$self: time is undefined" unless defined $deadline;
	
	return $self-> override_handler( 'watch_timer', $deadline, $callback)
		if $self-> {override};
	
	$deadline += time if $deadline < 1_000_000_000;
	my $rec = [
		$self,
		$deadline,
		$callback,
	];
	push @{$self-> {in}}, $rec;

	warn _d( $self, "> ", _ev($rec)) if $DEBUG;

	$LOOP-> after( $rec);
	
	return $rec;
}

# register a callback when another lambda exits
sub watch_lambda
{
	my ( $self, $lambda, $callback) = @_;

	croak "can't register events on a stopped lambda" if $self-> {stopped};
	croak "bad lambda" unless $lambda and $lambda->isa('IO::Lambda');

	croak "won't watch myself" if $self == $lambda;
	# XXX check cycling
	
	return $self-> override_handler( 'watch_lambda', $lambda, $callback)
		if $self-> {override};
	
	$lambda-> reset if $lambda-> is_stopped;

	my $rec = [
		$self,
		$lambda,
		$callback,
	];
	push @{$self-> {in}}, $rec;
	push @{$EVENTS{"$lambda"}}, $rec;

	$lambda-> start if $lambda-> is_passive;

	warn _d( $self, "> ", _ev($rec)) if $DEBUG;

	return $rec;
}

# watch the watchers
sub override
{
	my ( $self, $override) = @_;

	if ( $override) {
		$self-> {override} ||= [];
		push @{$self-> {override}}, $override;
	} else {
		return unless $self-> {override};
		my $ret = pop @{$self-> {override}};
		$self-> {override} = undef unless @{$self-> {override}};
		return $ret;
	}
}

sub override_handler
{
	my ( $self, @param) = @_;
	if ( 1 == @{$self-> {override}}) {
		my $o = $self-> {override}-> [0];
		local $self-> {override} = undef;
		return $o-> ( $self, @param);
	} else {
		my @r;
		my $o = pop @{$self-> {override}};
		if ( wantarray) {
			@r    = $o-> ( $self, @param);
		} else {
			$r[0] = $o-> ( $self, @param);
		}
		push @{$self->{override}}, $o;
		return wantarray ? @r : $r[0];
	}
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

	_d_in if $DEBUG;

	@{$self->{last}} = $rec-> [WATCH_CALLBACK]-> (
		$self, 
		(($#$rec == WATCH_IO_FLAGS) ? $rec-> [WATCH_IO_FLAGS] : ()),
		@{$self->{last}}
	) if $rec-> [WATCH_CALLBACK];

	_d_out if $DEBUG;
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

	_d_in if $DEBUG;
				
	@{$self->{last}} = 
		$rec-> [WATCH_CALLBACK] ? 
			$rec-> [WATCH_CALLBACK]-> (
				$self, 
				@{$rec-> [WATCH_LAMBDA]-> {last}}
			) : 
			@{$rec-> [WATCH_LAMBDA]-> {last}};

	_d_out if $DEBUG;
	warn $self-> _msg('tail') if $DEBUG;

	unless ( @$in) {
		warn _d( $self, 'stopped') if $DEBUG;
		$self-> {stopped} = 1;
	}
}

# Removes all events bound to the object, notifies the interested objects.
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

# Removes one event from queue; if that was the last event, triggers listening
# lambdas
sub cancel_event
{
	my ( $self, $rec) = @_;

	return unless @{$self-> {in}};

	$LOOP-> remove_event($self, $rec) if $LOOP;
	@{$self-> {in}} = grep { $_ != $rec } @{$self-> {in}};

	$self-> cancel_all_events unless @{$self-> {in}};
}

sub is_stopped  { $_[0]-> {stopped}  }
sub is_waiting  { not($_[0]->{stopped}) and @{$_[0]->{in}} }
sub is_passive  { not($_[0]->{stopped}) and not(@{$_[0]->{in}}) }
sub is_active   { $_[0]->{stopped} or @{$_[0]->{in}} }

# reset the state machine
sub reset
{
	my $self = shift;

	$self-> cancel_all_events;
	@{$self-> {last}} = ();
	delete $self-> {stopped};
	warn _d( $self, 'reset') if $DEBUG;
}

# start the state machine
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

# synchronisation

# drives objects dependant on the other objects until all of them
# are stopped
sub drive
{
	my $changed = 1;
	my $executed = 0;
	warn "IO::Lambda::drive --------\n" if $DEBUG;
	while ( $changed) {
		$changed = 0;

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

# do one quant
sub yield
{
	my $more_events = 0;

	# custom loops must not wait
	for ( @LOOPS) {
		next if $_-> empty;
		$_-> yield;
		$more_events = 1;
	}
	drive;

	# main loop waits, if anything
	unless ( $LOOP-> empty) {
		$LOOP-> yield;
		$more_events = 1;
	}

	$more_events = 1 if keys %EVENTS;
	return $more_events;
}


# wait for one lambda to stop
sub wait
{
	my $self = shift;
	if ( $self-> is_passive) {
		$self-> call(@_);
		$self-> start;
	}
	do {} while yield and not $self->{stopped};
	return $self-> peek;
}

# wait for all lambdas to stop
sub wait_for_all
{
	my @objects = @_;
	return unless @objects;
	$_-> start for grep { $_-> is_passive } @objects;
	my @ret;
	while ( 1) {
		push @ret, map { $_-> peek } grep { $_-> {stopped} } @objects;
		@objects = grep { not $_-> {stopped} } @objects;
		last unless @objects;
		yield;
	}
	return @ret;
}

# wait for at least one lambda to stop, return those that stopped
sub wait_for_any
{
	my @objects = @_;
	return unless @objects;
	$_-> start for grep { $_-> is_passive } @objects;
	while ( 1) {
		@objects = grep { $_-> {stopped} } @objects;
		return @objects if @objects;
		yield;
	}
}

# run the event loop until no lambdas are left in the blocking state
sub run { do {} while yield }

#
# Part II - Procedural interface to the lambda-style programming
#
#################################################################

sub _lambda_restart { die "lambda() is not restartable" }
sub lambda(&)
{
	my $cb  = $_[0];
	my $l   = __PACKAGE__-> new( sub {
		# initial lambda code is usually executed by tail/tails inside another lambda,
		# so protect the upper-level context
		local $THIS     = shift;
		local @CONTEXT  = ();
		local $CALLBACK = $cb;
		local $METHOD   = \&_lambda_restart;
		$cb ? $cb-> (@_) : @_;
	});
	$l-> {caller} = join(':', (caller)[1,2]) if $DEBUG;
	$l;
}

# re-enter the latest (or other) frame
sub again
{
	( $METHOD, $CALLBACK) = @_ if 2 == @_;
	defined($METHOD) ? 
		$METHOD-> ( $CALLBACK) : 
		croak "again predicate outside of a restartable call" 
}

# define context
sub this         { @_ ? ($THIS, @CONTEXT) = @_ : $THIS }
sub context      { @_ ? @CONTEXT = @_ : @CONTEXT }
sub this_frame   { @_ ? ( $METHOD, $CALLBACK) = @_ : ( $METHOD, $CALLBACK) }

sub state($)
{
	my $this = ($_[0] && ref($_[0])) ? shift(@_) : this;
	@_ ? $this-> {state} = $_[0] : return $this-> {state};
}

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
		$cb ? sub {
			$THIS     = shift;
			@CONTEXT  = @ctx;
			$METHOD   = $method;
			$CALLBACK = $cb;
			$cb-> (@_);
		} : undef,
	);
}

# tail( $lambda, @param) -- initialize $lambda with @param, and wait for it
sub tail(&)
{
	my ( $lambda, @param) = context;
	$lambda-> reset if $lambda-> is_stopped;
	$lambda-> call( @param);
	$THIS-> add_tail( shift, \&tail, $lambda, $lambda, @param);
}

# tails(@lambdas) -- wait for all lambdas to finish
sub tails(&)
{
	my $cb = $_[0];
	my @lambdas = context;
	my $n = $#lambdas;
	croak "no tails" unless @lambdas;

	my @ret;
	my $watcher;
	$watcher = sub {
		$THIS     = shift;
		push @ret, @_;
		return if $n--;

		@CONTEXT  = @lambdas;
		$METHOD   = \&tails;
		$CALLBACK = $cb;
		$cb ? $cb-> (@ret) : @ret;
	};
	my $this = $THIS;
	$this-> watch_lambda( $_, $watcher) for @lambdas;
}

#
# Part III - High order lambdas
#
################################################################

# sysread lambda wrapper
#
# ioresult    :: ($result, $error)
# sysreader() :: ($fh, $buf, $offset, $deadline) -> ioresult
sub sysreader (){ lambda 
{
	my ( $fh, $buf, $length, $deadline) = @_;
	$$buf = '' unless defined $$buf;

	this-> watch_io( IO_READ, $fh, $deadline, sub {
		return undef, 'timeout' unless shift;
		my $n = sysread( $fh, $$buf, $length, length($$buf));
		if ( $DEBUG) {
			warn "fh(", fileno($fh), ") read ", ( defined($n) ? "$n bytes" : "error $!"), "\n";
			warn substr( $$buf, length($$buf) - $n) if $DEBUG > 2 and $n > 0;
		}
		return undef, $! unless defined $n;
		return $n;
	})
}}

# syswrite() lambda wrapper
#
# syswriter() :: ($fh, $buf, $length, $offset, $deadline) -> ioresult
sub syswriter (){ lambda
{
	my ( $fh, $buf, $length, $offset, $deadline) = @_;

	this-> watch_io( IO_WRITE, $fh, $deadline, sub {
		return undef, 'timeout' unless shift;
		my $n = syswrite( $fh, $$buf, $length, $offset);
		if ( $DEBUG) {
			warn "fh(", fileno($fh), ") wrote ", ( defined($n) ? "$n bytes" : "error $!"), "\n";
			warn substr( $$buf, $offset, $n) if $DEBUG > 2 and $n > 0;
		}
		return undef, $! unless defined $n;
		return $n;
	});
}}

sub _match 
{
	my ( $cond, $buf) = @_;

	return unless defined $cond;

	return ($$buf =~ /($cond)/)[0] if ref($cond) eq 'Regexp';
	return $cond->($buf) if ref($cond) eq 'CODE';
	return length($$buf) >= $cond;
}

# read from stream until condition is met
#
# readbuf($reader) :: ($fh, $buf, $cond, $deadline) -> ioresult
sub readbuf
{
	my $reader = shift || sysreader;

	lambda {
		my ( $fh, $buf, $cond, $deadline) = @_;
		
		$$buf = "" unless defined $$buf;

		my $match = _match( $cond, $buf);
		return $match if $match;
	
		my ($maxbytes, $bufsize);
		$maxbytes = $cond if defined($cond) and not ref($cond) and $cond > 0;
		$bufsize = defined($maxbytes) ? $maxbytes : 65536;
		
		my $savepos = pos($$buf); # useful when $cond is a regexp

		context $reader, $fh, $buf, $bufsize, $deadline;
	tail {
		pos($$buf) = $savepos;

		my $bytes = shift;
		return undef, shift unless defined $bytes;
		
		unless ( $bytes) {
			return 1 unless defined $cond;
			return undef, 'eof';
		}
		
		# got line? return it
		my $match = _match( $cond, $buf);
		return $match if $match;
		
		# otherwise, just wait for more data
		$bufsize -= $bytes if defined $maxbytes;

		context $reader, $fh, $buf, $bufsize, $deadline;
		again;
	}}
}

# curry readbuf()
#
# getline($reader) :: ($fh, $buf, $deadline) -> ioresult
sub getline
{
	my $reader = shift;
	lambda {
		my ( $fh, $buf, $deadline) = @_;
		context readbuf($reader), $fh, $buf, qr/^[^\n]*\n/, $deadline;
		&tail();
	}
}

# write whole buffer to stream
#
# writebuf($writer) :: syswriter
sub writebuf
{
	my $writer = shift || syswriter;

	lambda {
		my ( $fh, $buf, $len, $offs, $deadline) = @_;

		$$buf = "" unless defined $$buf;
		$offs = 0 unless defined $offs;
		$len  = length $$buf unless defined $len;
		my $written = 0;
		
		context $writer, $fh, $buf, $len, $offs, $deadline;
	tail {
		my $bytes = shift;
		return undef, shift unless defined $bytes;

		$offs    += $bytes;
		$written += $bytes;
		$len     -= $bytes;
		return $written if $len <= 0;

		context $writer, $fh, $buf, $len, $offs, $deadline;
		again;
	}}
}

#
# Part IV - Developer API for custom condvars and event loops
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
when one employs threads, coroutines, or Co-processes. Otherwise state machines
are to be built, often quite complex, which fact doesn't help the clarity of
the code. This module uses closures to achieve clarity of sequential
programming with single-process, single-thread, non-blocking I/O.

=head1 SYNOPSIS

=head2 Basics

Prerequisite

    use IO::Lambda qw(:lambda);

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
	tails { sort @_ }; # order is not guaranteed
    };
    print $q-> wait; # will print 23

=head2 Non-blocking I/O

Given a socket, create a lambda that implements http protocol

    sub talk
    {
        my $req    = shift;
        my $socket = IO::Socket::INET-> new( PeerAddr => $req-> host, PeerPort => 80);

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
	tails { print for @_ };
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
    use IO::Lambda qw(:lambda);
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

Lambdas are usually not started explicitly; the function that waits for a
lambda, also starts it. C<wait>, the synchronous waiter, and C<tail>/C<tails>, the
asynchronous ones, start passive lambdas when called. Lambda is finished when
there are no more events to listen to. The example lambda above will finish
right after C<print> statement.

Lambda can listen to events by calling predicates, that internally subscribe
the lambda object to corresponding file handles, timers, and other lambdas.
There are only those three types of events that basically constitute everything
needed for building a state machine driven by external events, in particular,
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

will print indeterminable number of ones.

=head2 Contexts

Each lambda callback (further on, merely lambda) executes in its own, private
context. The context here means that all predicates register callbacks on an
implicitly given lambda object, and keep the passed parameters on the context
stack. The fact that context is preserved between states, helps building terser
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

And as the context is kept, the current lambda object is also, in C<this>
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

A lambda is initially called with arguments passed from outside. These arguments
can be stored using C<call> method; C<wait> and C<tail> also issue C<call>
internally, thus replacing any previous data stored by C<call>. Inside the
lambda these arguments are available as C<@_>.

Whatever is returned by a predicate callback (including C<lambda> predicate),
will be passed as C<@_> to the next callback, or to the outside, if the lambda is
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

C<wait> is not the only function that synchronises input and output data.
C<wait_for_all> method waits for all lambdas, including the caller, to finish.
It returns collected results of all the objects in a single list.
C<wait_for_any> method waits for at least one lambda, from the list of passed
lambdas (again, including the caller), to finish. It returns list of finished
objects as soon as possible.

=head2 Time

Timers and I/O timeouts can be given not only in the timeout values, as it
usually is in event libraries, but also as deadlines in (fractional) seconds
since epoch. This decision, strange at first sight, actually helps a lot when
total execution time is to be tracked. For example, the following code reads as
many bytes from a socket within 5 seconds:

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

Rewriting the same code with C<read> semantics that accepts time as timeout instead, 
would be not that elegant:
   
   lambda {
       my $buf = '';
       my $time_left = 5;
       my $now = time;
       context $socket, $time_left;
       read {
           if ( shift ) {
	       if (sysread $socket, $buf, 1024, length($buf)) {
	           $time_left -= (time - $now);
		   $now = time;
		   context $socket, $time_left;
	           return again;
	       }
	   } else {
	       print "oops! a timeout\n";
	   }
	   $buf;
       }
   };

However, the exact opposite is true for C<sleep>. The following two lines
both sleep 5 seconds:

   lambda { context 5;        sleep {} }
   lambda { context time + 5; sleep {} }

Internally, timers use C<Time::HiRes::time> that gives fractional number of
seconds. This however is not required for the caller, in which case timeouts
will simply be less precise, and will jitter plus-minus half a second.

=head2 Predicates

All predicates receive their parameters from the context stack, or simply the
context. The only parameter passed to them by using perl call, is a callback
itself.  Predicates can also be called without a callback, in which case, they
will pass further data that otherwise would be passed as C<@_> to the
callback. Thus, a predicate can be called either as

    read { .. code ... }

or 

    &read(); # no callback

Predicates can either be used after explicit exporting

   use IO::Lambda qw(:lambda);
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
that means that it will never be called with FALSE.

=item write($filehandle, $deadline = undef)

Exactly same as C<read>, but executes when C<$filehandle> becomes writable.

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

=item tail($lambda, @parameters)

Issues C<< $lambda-> call(@parameters) >>, then waits for the C<$lambda>
to complete.

=item tails(@lambdas)

Executes when all objects in C<@lambdas> are finished, returns the collected,
unordered results of the objects.

=item again(@frame = ())

Restarts the current state with the current context. All the predicates above,
excluding C<lambda>, are restartable with C<again> call (see C<start> for
restarting a C<lambda>). The code

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
       &tail();
   };

C<again> passes the current context to the predicate.

If C<@frame> is provided, then it is treated as result of previous C<this_frame> call.
It contains data sufficient to restarting another call, instead of the current.
See C<this_frame> for details.

=item context @ctx

If called with no parameters, returns the current context, otherwise
replaces the current context with C<@ctx>. It is thus not possible 
(not that it is practical anyway) to clear the context with this call.
If really needed, use C<this(this)> syntax.

=item this $this, @ctx

If called with no parameters, returns the current lambda.
Otherwise, replaces both the current lambda and the current context.
Can be useful either when juggling with several lambdas, or as a
convenience over C<my> variables, for example,

    this lambda { ... };
    this-> wait;

instead of

    my $q = lambda { ... };
    $q-> wait;

=item this_frame(@frame)

If called without parameters, returns the current callback frame, that
can be later used in C<again>. Otherwise, replaces the internal frame
variables, that doesn't affect anything immediately, but will be used by C<again>
that is called without parameters.

This property is only used when the predicate inside which C<this_frame> was
fetched, is restartable. Since it is not a requirement for a user-defined
predicate to be restartable, this property is not universally useful.

Example:

    context lambda { 1 };
    tail {
        return if 3 == shift;
    	my @frame = this_frame;
        context lambda { 2 };
	tail {
	   context lambda { 3 };
	   again( @frame);
	}
    }

The outermost tail callback will be called twice: first time in the normal course of event,
and second time as a result of the C<again> call. C<this_frame> and C<again> thus provide
a kind of restartable continuations.

=back

=head2 Stream I/O

The whole point of this module is to help building complex protocols in a
clear, consequent programming style. Consider how perl's low-level C<sysread>
and C<syswrite> relate to its higher-level C<readline>, where the latter not
only does the buffering, but also recognizes C<$/> as input record separator.
The section above described lower-level lambda I/O predicates, that are only
useful for C<sysread> and C<syswrite>; this section tells about higher-level
lambdas that relate to these low-level ones, as the aforementioned C<readline>
relates to C<sysread>.

All functions in this section return the lambda, that does the actual work.  Not
unlike as a class constructor returns a newly created class instance, these
functions return newly created lambdas. Therefore, these functions are
documented here as having two inputs and one output, as for example a function
C<sysreader> is a function that takes 0 parameters, always returns a new
lambda, and this lambda, in turn, takes four parameters and returns two. This
function will be described as

    # sysreader() :: ($fh,$buf,$length,$deadline) -> ($result,$error)

Since all stream I/O lambdas return same set of scalars, the return type
will be further on referred as C<ioresult>:

    # ioresult    :: ($result, $error)
    # sysreader() :: ($fh,$buf,$length,$deadline) -> ioresult

C<ioresult>'s first scalar is defined on success, and is not otherwise.  In the
latter case, the second scalar contains the error, usually either C<$!> or
C<'timeout'> (if C<$deadline> was set).

=over

=item sysreader() :: ($fh, $buf, $length, $deadline) -> ioresult

Creates a lambda that accepts all the parameters used by C<sysread> (except
C<$offset> though), plus C<$deadline>. The lambda tries to read C<$length>
bytes from C<$fh> into C<$buf>, when C<$fh> becomes available for reading. If
C<$deadline> expires, fails with C<'timeout'> error. On successful read,
returns number of bytes read, or C<$!> otherwise.

=item syswriter() :: ($fh, $buf, $length, $offset, $deadline) -> ioresult

Creates a lambda that accepts all the parameters used by C<syswrite> plus
C<$deadline>. The lambda tries to write C<$length> bytes to C<$fh> from C<$buf>
from C<$offset>, when C<$fh> becomes available for writing. If C<$deadline>
expires, fails with C<'timeout'> error. On successful write, returns number of
bytes written, or C<$!> otherwise.

=item readbuf($reader = sysreader()) :: ($fh, $buf, $cond, $deadline) -> ioresult

Creates a lambda that is able to perform buffered reads from C<$fh>, either
using custom lambda C<reader>, or using one newly generated by C<sysreader>.
The lambda when called, will read continually from C<$fh> into C<$buf>, and
will either fail on timeout, I/O error, or end of file, or succeed if C<$cond>
condition matches.

The condition C<$cond> is a "smart match" of sorts, and can be one of:

=over

=item integer

The lambda will succeed when exactly C<$cond> bytes are read from C<$fh>.

=item regexp

The lambda will succeed when C<$cond> matches the content of C<$buf>.
Note that C<readbuf> saves and restores value of C<pos($$buf)>, so use of
C<\G> is encouraged here.

=item coderef :: ($buf -> BOOL)

The lambda will succeed if coderef called with C<$buf> returns true value.

=item undef

The lambda will succeed on end of file. Note that for all other conditions end
of file is reported as an error, with literal C<"eof"> string.

=back

=item writebuf($writer) :: ($fh, $buf, $length, $offset, $deadline) -> ioresult

Creates a lambda that is able to perform buffered writes to C<$fh>, either
using custom lambda C<writer>, or using one newly generated by C<syswriter>.
That lambda, in turn, will write continually C<$buf> (from C<$offset>,
C<$length> bytes) and will either fail on timeout or I/O error, or succeed when
C<$length> bytes are written successfully.

=item getline($reader) :: ($fh, $buf, $deadline) -> ioresult

Same as C<readbuf>, but succeeds when a string of bytes ended by a newline
is read.

=back

=head2 Object API

This section lists methods of C<IO::Lambda> class. Note that by design all
lambda-style functionality is also available for object-style programming.
Together with the fact that lambda syntax is not exported by default, it thus
leaves a place for possible implementations of independent syntaxes, either
with or without lambdas, on top of the object API, without accessing the
internals.

The object API is mostly targeted to developers that need to connect
third-party asynchronous events with the lambda interface.

=over

=item new

Creates new C<IO::Lambda> object in the passive state.

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

=item start

Starts a passive lambda. Can be used for effective restart of the whole lambda;
the only requirement is that the lambda should have no pending events.

=item call @args

Stores C<@args> internally, to be passed on to the first callback. Only
works in passive state, croaks otherwise. If called multiple times,
arguments from the previous calls are overwritten.

=item terminate @args

Cancels all watchers and resets lambda to the stopped state.  If there are any
lambdas that watch for this object, these will be notified first. C<@args> will
be stored and available for later calls by C<peek>.

=item wait @args

Waits for the caller lambda to finish, returns the result of C<peek>.
If the object was in passive state, calls C<call(@args)>, otherwise
C<@args> are not used.

=item wait_for_all @lambdas

Waits for caller lambda and C<@lambdas> to finish. Returns
collection of C<peek> results for all objects. The results
are unordered.

=item wait_for_any @lambdas

Waits for at least one lambda from list of caller lambda and C<@lambdas> to
finish.  Returns list of finished objects.

=item yield

Runs onle round of dispatching events. Returns 1 if there are more events
in internal queues, 0 otherwise.

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
then stops.

Note that C<resolve> doesn't provide any means to call associated
callbacks, which is intentional.

=item override $CODEREF

Installs a C<$CODEREF> as a overriding hook for C<watch_lambda>, C<watch_io>,
and C<watch_timer> methods. Whenever a lambda calls one of these methods, the
hook will be called instead, that should be able to analyze the call and pass
or deny it from the further processing. See also C<state>.

There can be stacked more than one C<override> handlers; if C<$CODEREF> is C<undef>,
removes the last registered hook.

Example:

    my $q = lambda { ... tail { ... }};
    $q-> override( sub {
        my ( $self, $method, @param) = @_;
	if ( $method eq 'watch_lambda') {
	    # pass
            $self-> $method(@param);
	} else {
	    # deny and rewrite result
	    return 42;
	}
    });

=item state $STATE

Helper function for explicit naming of predicate calls. The function stores
C<$STATE> string on the current lambda, so that eventual C<override>, needing
to override internal states of the lambda, will make use of the string to
identify a particular state.

The rule of thumb is to use it when a lambda contains more than one predicate
of a certain type; for example the code

   tail {
   tail {
      ...
   }}

is therefore better to be written as
    
   state A => tail {
   state B => tail {
      ...
   }}

=back

=head1 SEE ALSO

L<Coro>, L<threads>, L<POE>.

The package contains backends for other libraries that benefit from 
asynchronous I/O, but may or may not list them as explicit dependency.
If you need to use these, install these separately:

=over

=item *

L<IO::Lambda::SNMP> requires L<SNMP>.

=item *

Lambda C<pid> in L<IO::Lambda::Signal> requires functioning C<POSIX::waitpid>.

=item *

L<IO::Lambda::HTTP::Authen::NTLM> requires L<Authen::NTLM>.

=back

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2008 capmon ApS. All rights reserved.

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
