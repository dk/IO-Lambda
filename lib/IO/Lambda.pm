# $Id: Lambda.pm,v 1.6 2007/12/13 23:45:48 dk Exp $

package IO::Lambda;

use Carp;
use strict;
use warnings;
use Exporter;
use Scalar::Util qw(weaken);
use vars qw(
	$LOOP @OBJECTS
	$VERSION @ISA
	@EXPORT_OK %EXPORT_TAGS @EXPORT_CONSTANTS @EXPORT_CLIENT
	$THIS @CONTEXT $METHOD $CALLBACK @CTX_STACK
	$DEBUG
);
$VERSION     = 0.02;
@ISA         = qw(Exporter);
@EXPORT_CONSTANTS = qw(
	IO_READ IO_WRITE IO_EXCEPTION 
	WATCH_OBJ WATCH_DEADLINE WATCH_LAMBDA WATCH_CALLBACK
	WATCH_IO_HANDLE WATCH_IO_FLAGS
);
@EXPORT_CLIENT = qw(
	this context lambda restart again
	read write sleep tail tails
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
	warn _d( $self, 'created at ', join(':', (caller(1))[1,2])) if $DEBUG;
	$self;
}

sub DESTROY
{
	my $self = $_[0];
	@OBJECTS = grep { defined($_) and $_ != $self } @OBJECTS;
	$LOOP-> remove( $self ) if $LOOP and @{$self-> {in}};
	@{$self-> {in}}  = ();
}

sub _coderef
{
	my $self = $_[0];
	sub { $self-> call(@_) }
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
	_d($_[0], '*', '(',
	join(',', map { 
		defined($_) ? $_ : 'undef'
	} @{$_[0]->{last}}),
	')')
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

	croak "bad lambda" unless $lambda and $lambda->isa('IO::Lambda');
	croak "won't watch myself" if $self == $lambda;

	my $rec = [
		$self,
		$lambda,
		$callback,
	];
	push @{$self-> {in}}, $rec;

	warn _d( $self, "> ", _ev($rec)) if $DEBUG;
}

# handle uncoming asynchronous events
sub io_handler
{
	my ( $self, $rec) = @_;

	warn _d( $self, '< ', _ev($rec)) if $DEBUG;

	my $in = $self-> {in};
	my $nn = @$in;
	@$in = grep { $rec != $_ } @$in;
	die _d($self, 'stray ', _ev($rec)) if $nn == @$in or $self != $rec->[WATCH_OBJ];

	@{$self->{last}} = $rec-> [WATCH_CALLBACK]-> (
		$self, 
		(($#$rec == WATCH_IO_FLAGS) ? $rec-> [WATCH_IO_FLAGS] : ()),
		@{$self->{last}}
	);
	warn $self-> _msg if $DEBUG;

	unless ( @$in) {
		warn _d( $self, 'stopped') if $DEBUG;
		$self-> {stopped}++;
	}
}

sub stopped  { $_[0]-> {stopped}  }

# resets the state machine
sub reset
{
	my $self = shift;
	$LOOP-> remove( $self ) if @{$self-> {in}};
	@{$self-> {in}}   = ();
	@{$self-> {last}} = ();
	delete $self-> {stopped};
	warn _d( $self, 'reset') if $DEBUG;
}

# advances all possible states, returns a flag that is
# 1 - no more states to call (also if stopped)
# 0 - have some asynchronous states left
sub step
{
	my $self = shift;

	return 1 if $self-> {stopped};

	die _d($self, 'cyclic dependency detected') if $self-> {locked}; 
			
	unless ( @{$self->{in}} ) {
		# kick-start the execution chain
		if ( $self-> {start}) {
			warn _d( $self, 'started') if $DEBUG;
			@{$self->{last}} = $self-> {start}-> ($self, @{$self->{last}}, @_);
			warn $self-> _msg if $DEBUG;
		}
	}

	# drive the states
	my $changed = 1;
	$self-> {locked} = 1;
	my $in = $self-> {in};
	while ( $changed) {
		$changed = 0;
		for my $rec ( @$in) {
			# asyncrohous event
			unless (ref($rec-> [WATCH_LAMBDA])) {
				warn _d( $self, 'still waiting for ', _ev($rec)) if $DEBUG;
				next;
			}
			# synchronous event
			my $lambda = $rec->[WATCH_LAMBDA];
			unless ( $lambda-> step) {
				warn _d( $self, 'still waiting for ', _ev($rec)) if $DEBUG;
				next;
			}
			$changed = 1;
		
			warn _d( $self, '< ', _ev($rec)) if $DEBUG;

			@{$self->{last}} = $rec-> [WATCH_CALLBACK]-> ($self, @{$lambda->{last}});
			warn $self-> _msg if $DEBUG;
			@$in = grep { $rec != $_ } @$in;
		}
	}
	delete $self-> {locked};

	unless ( @$in) {
		warn _d( $self, 'stopped') if $DEBUG;
		$self-> {stopped}++;
	}

	return $self-> {stopped};
}

# peek into the current state
sub peek { wantarray ? @{$_[0]->{last}} : $_[0]-> {last} }

# pass initial parameters to lambda
sub call 
{
	my $self = shift;

	croak "can't call stopped lambda" if $self-> {stopped};
	croak "can't call started lambda" if @{$self->{in}};

	@{$self-> {last}} = @_;
	$self;
}

# abandon all states and stop with constant message
sub terminate
{
	my ( $self, @error) = @_;
	warn _d( $self, "terminate(@error)") if $DEBUG;

	$LOOP-> remove( $self ) if @{$self-> {in}};
	@{$self-> {in}}  = ();
	$self-> {stopped} = 1;
	$self-> {last} = \@error;
	warn $self-> _msg if $DEBUG;
}

# synchronization

# drives all objects until all of them
# are either stopped, or in a blocking state
sub drive
{
	my $changed = 1;
	warn "IO::Lambda::drive --------\n" if $DEBUG;
	while ( $changed) {
		$changed = 0;
		for my $o ( grep { not $_-> {stopped} } @OBJECTS) {
			next unless $o-> step;
			$changed = 1;
		}
	warn "IO::Lambda::drive .........\n" if $DEBUG and $changed;
	}
	warn "IO::Lambda::drive +++++++++\n" if $DEBUG;
}

# wait for all lambdas to stop
sub wait
{
	my $self = shift;
	$self-> call(@_) if not($self->{stopped}) and not(@{$self->{in}});
	while ( 1) {
		drive;
		last if $self-> {stopped};
		$LOOP-> yield;
	}
	return wantarray ? $self-> peek : $self-> peek-> [0];
}

sub wait_for_all
{
	my @objects = @_;
	while ( 1) {
		drive;
		@objects = grep { not $_-> {stopped} } @objects;
		last unless @objects;
		$LOOP-> yield;
	}
}

# wait for at least one lambda to stop, returns those that stopped
sub wait_for_any
{
	my @objects = @_;
	$_-> step for @objects;
	while ( 1) {
		drive;
		@objects = grep { $_-> {stopped} } @objects;
		return @objects if @objects;
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
sub push_context { push @CTX_STACK, [ $THIS, $METHOD, $CALLBACK, @CONTEXT ] }
sub pop_context  { ($THIS, $METHOD, $CALLBACK, @CONTEXT) = @{ pop @CTX_STACK } }


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

# common wrapper for declaration of lambda-watching user predicates
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

# tail($lambda) -- execute block when $lambda is done
sub tail(&) { $THIS-> add_tail( shift, \&tail, @CONTEXT[0,0]) }

# tails(@lambdas) -- wait for all lambdas to finish
sub tails(&)
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
		$METHOD   = \&tails;
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
                return $buf unless 
                    sysread( $socket, $buf, 1024, length($buf));
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

=head1 SEE ALSO

L<Coro>, L<threads>, L<Event::Lib>.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2007 capmon ApS. All rights reserved.

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
