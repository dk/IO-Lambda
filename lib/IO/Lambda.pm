# $Id: Lambda.pm,v 1.1 2007/12/11 14:48:38 dk Exp $

package IO::Lambda;

use strict;
use warnings;
use Exporter;
use vars qw(
	$VERSION @ISA
	@EXPORT_OK %EXPORT_TAGS 
	$SELF @CONTEXT $METHOD $CALLBACK @CTX_STACK
	$DEBUG
);
$VERSION     = 0.01; 
@ISA         = qw(Exporter);
@EXPORT_OK   = qw(
	FH_READ FH_WRITE FH_EXCEPTION 
	self context self_context again push_context pop_context
	read write sleep finally pipeline
);
%EXPORT_TAGS = ( all => \@EXPORT_OK);

use constant FH_READ      => 4;
use constant FH_WRITE     => 2;
use constant FH_EXCEPTION => 1;

sub new
{ 
	my ( $class, %opt) = @_;

	my $self = bless {
		next    => [],
		last    => [],
		tail    => undef,
		loop    => ( $opt{loop} ? $opt{loop} : IO::Lambda::Loop-> new ),
	}, $class;

	$self-> $_( $opt{$_}) for 
		grep { exists $opt{$_} } 
		qw(tail);

	return $self;
}

sub DESTROY
{
	my $self = $_[0];
	if ( $self-> {loop}) {
		$self-> {loop}-> remove( $self) if @{$self-> {next}};
		@{$self-> {next}} = ();
		$self-> {loop} = undef;
	}
}

# final action 
sub tail
{ 
	my ( $self, $tail) = @_;
	return $self-> {tail} unless $#_;
	$self-> {tail} = $tail;
	warn "$self: register final dispatch $tail\n" if $DEBUG;
		
	# finished before coupling?
	$self-> dispatch_tail( @{$self->{last}}) 
		if $tail and not @{$self->{next}};
}

sub peek { wantarray ? @{$_[0]->{last}} : $_[0]-> {last} }

sub fail
{
	my ( $self, $error) = @_;
	warn "$self: fail($error)\n" if $DEBUG;	
	$self-> dispatch_tail($error);
}

# called from event loop; info is either a combination of IO flags (READ/WRITE/EXCEPTION)
# or undef if this was a timer event
sub callback_timer { 
	warn "$_[0]: timer expired\n" if $DEBUG;	
	goto &dispatch 
}

sub callback_handle
{
	my ( $self, $flags, $handle, $cb, @param) = @_;
	warn "$self: handle #", fileno($handle), " called back with ", 
		($flags ? "flags=$flags" : 'a timeout'),
		"\n" if $DEBUG;	
#	$handle-> blocking(0); # do we need that?
	$self-> dispatch( $cb, $flags, @param);
}


# Calls all internal states, until none left.
# After that propagates the event to the external object or callback.
sub dispatch
{
	my ( $self, $cb, @param) = @_;

	my $n = $self-> {next};
	my $nn = @$n;
	@$n = grep { $cb != $_ } @$n;
	die "stray callback" if $nn == @$n;

	@param = $cb-> ($self, @param);
	$self-> {last} = \@param;

	return if @$n;
	return unless $self-> {tail};

	$self-> dispatch_tail(@param);
}

# callout to the next lambda in the pipeline
sub dispatch_tail
{
	my ( $self, @param) = @_;

	die "dispatch_tail called when there are un-called states left" if @{$self->{next}};

	$self-> {last} = \@param;
	return unless $self-> {tail};

	# dispatch to the next object that waits for us
	my $last = $self-> {last};
	my $tail = $self-> {tail};
	$self-> {last} = [];
	$self-> {tail} = undef;

	warn "$self: dispatch tail to $tail( @$last )\n" if $DEBUG;

	if ( ref($tail) eq 'CODE') {
		# either plain callback
		$tail-> ( $self, @$last );
	} else {
		# or a IO::Lambda object
		$tail-> dispatch( @$last );
	}
}

# register an IO event
sub watch
{
	my ( $self, $flags, $handle, $deadline, $cb) = @_;

#	$handle-> blocking(0); # do we need that?
	push @{$self-> {next}}, $cb;
	
	warn "$self: register IO(", $flags, ") ",
		(defined($deadline) ? "deadline($deadline) " : ''),
		"handle #", fileno($handle), "\n" if $DEBUG;
	$self-> {loop}-> watch( $flags, $handle, $deadline, $self, $cb);
}

# register a timeout
sub after
{
	my ( $self, $deadline, $cb) = @_;

	die "time is undefined" unless defined $deadline;

	push @{$self-> {next}}, $cb;

	warn "$self: register timer deadline $deadline\n" if $DEBUG;
	$self-> {loop}-> after( $deadline, $self, $cb);
}

sub add_callback
{
	my ( $self, $cb) = @_;
	push @{$self-> {next}}, $cb;
}

# loop handling
sub loop       { $_[0]-> {loop} }
sub run        { $_[0]-> {loop}-> run }
sub is_charged { @{$_[0]->{next}} or $_[0]->{tail} }

sub wait { goto &wait_for_all }
sub wait_for_all
{
	my $loop    = $_[0]-> loop;
	my @objects = @_;
	while ( 1) {
		@objects = grep { $_-> is_charged } @objects;
		last unless @objects;
		$loop-> yield;
	}
}

sub wait_for_any
{
	my $loop    = $_[0]-> loop;
	my @objects = @_;
	while ( 1) {
		@objects = grep { ! $_-> is_charged } @objects;
		return @objects if @objects;
		$loop-> yield;
	}
}

# the following enables non-method interface for callbacks, for
# the prettier code style:
# 
#  context( $socket, $deadline);
#  read {
#     ....
#  }
#

# define context
sub self_context { @_ ? ( $SELF,   @CONTEXT ) = @_ : ( $SELF,   @CONTEXT ) }
sub self         { @_ ? $SELF = $_[0] : $SELF }
sub context      { @_ ? @CONTEXT = @_ : @CONTEXT }
sub restart      { @_ ? ( $METHOD, $CALLBACK) = @_ : ( $METHOD, $CALLBACK) }
sub push_context { push @CTX_STACK, [ $SELF, $METHOD, $CALLBACK, @CONTEXT ] }
sub pop_context  { ($SELF, $METHOD, $CALLBACK, @CONTEXT) = @{ pop @CTX_STACK } }

#
# Predicates:
#

# read($handle,$deadline)
sub read(&)
{
	my $cb = $_[0];
	my ($handle, $deadline) = @CONTEXT;
	$SELF-> watch(
		FH_READ,
		$handle, $deadline,
		sub {
			$SELF     = shift;
			@CONTEXT  = ( $handle, $deadline);
			$METHOD   = \&read;
			$CALLBACK = $cb;
			$cb-> (@_);
		}
	);
}

# write($handle,$deadline)
sub write(&)
{
	my $cb = $_[0];
	my ($handle, $deadline) = @CONTEXT;
	$SELF-> watch(
		FH_WRITE,
		$handle, $deadline,
		sub {
			$SELF     = shift;
			@CONTEXT  = ( $handle, $deadline);
			$METHOD   = \&write;
			$CALLBACK = $cb;
			$cb-> (@_);
		}
	);
}

# sleep($deadline)
sub sleep(&)
{
	my $cb = $_[0];
	my ($deadline) = @CONTEXT;
	$SELF-> after(
		$deadline,
		sub {
			$SELF     = shift;
			@CONTEXT  = ($deadline);
			$METHOD   = \&sleep;
			$CALLBACK = $cb;
			$cb-> ();
		},
	);
}

sub again
{ 
	defined($METHOD) ? 
		$METHOD-> ( $CALLBACK ) : 
		die "again predicate outside of a restartable call" 
}

# finally() -- executes block when done; will do immediately if nothing left
sub finally(&)
{
	my $cb = $_[0];
	$SELF-> tail( sub {
		$SELF     = shift;
		@CONTEXT  = ();
		$METHOD   = \&finally;
		$CALLBACK = $cb;
		$cb-> (@_);
	});
}

# pipeline($lambda) -- execute block when $lambda is done
sub pipeline(&)
{
	my $cb = $_[0];
	my $self = $SELF;
	die "won't pipeline to myself -- use either 'finally', or 'again' inside 'pipeline'"
		if $SELF == $CONTEXT[0];
	my $wrapper = sub {
		shift;
		$cb-> (@_);
	};
	$self-> add_callback( $wrapper);
	$CONTEXT[0]-> tail( sub {
		$SELF     = $self;
		@CONTEXT  = (shift);
		$METHOD   = \&pipeline;
		$CALLBACK = $cb;
		$self-> dispatch( $wrapper, @_);
	});
}

package IO::Lambda::Loop;
use vars qw($LOOP $DEFAULT);
use strict;
use warnings;

$DEFAULT = 'Select';
sub default { $DEFAULT = shift }

sub new
{
	return $LOOP if $LOOP;

	my ( $class, %opt) = @_;

	$opt{type} ||= $DEFAULT;
	$class .= "::$opt{type}";
	eval "use $class;";
	die $@ if $@;

	return $LOOP = $class-> new();
}

sub run { $LOOP-> run }

1;

=pod

=cut
