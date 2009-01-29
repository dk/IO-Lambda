# $Id: Mutex.pm,v 1.5 2009/01/29 16:29:13 dk Exp $
package IO::Lambda::Mutex;
use vars qw($DEBUG @ISA);
$DEBUG = $IO::Lambda::DEBUG{mutex} || 0;
@ISA = qw(Exporter);
@EXPORT_OK = qw(mutex);
%EXPORT_TAGS = ( all => \@EXPORT_OK);

use strict;
use IO::Lambda qw(:all);

sub new
{
	return bless {
		taken  => 0,
		queue  => [],
	}, shift;
}

sub is_taken {     $_[0]-> {taken} }
sub is_free  { not $_[0]-> {taken} }

# non-blocking take
sub take
{
	my $self = shift;
	warn "$self is taken\n" if $DEBUG and not $self->{taken};
	return $self-> {taken} ? 0 : ($self-> {taken} = 1);
}

# remove the lambda from queue
sub remove
{
	my ( $self, $lambda) = @_;
	my $found;
	my $q = $self-> {queue};
	for ( my $i = 0; $i < @$q; $i ++) {
		next if $q->[$i] != $lambda;
		$found = $i;
		last;
	}
	if ( defined $found) {
		splice( @$q, $found, 1);
		$self-> release unless @$q; 
	} else {
		warn "$self failed to remove $lambda from queue\n" if $DEBUG;
	}
}

sub waiter
{
	my ( $self, $timeout) = @_;

	# mutex is free, can take now
	unless ( $self-> {taken}) {
		$self-> take;
		return lambda { undef };
	}

	# mutex is not free, wait for it
	my $waiter = IO::Lambda-> new;
	my $bind   = $waiter-> bind( sub {
		my $w = shift;
		# lambda was terminated, relinquish waiting and kill timeout
		$self-> remove($w);
		$w-> cancel_event($timeout) if defined $timeout;
		return @_; # propagate error
	});
	push @{$self-> {queue}}, $waiter;

	$timeout = $waiter-> watch_timer( $timeout, sub {
		$self-> remove($waiter);
		$waiter-> resolve($bind);
		return 'timeout';
	}) if defined $timeout;

	return $waiter;
}

sub release
{
	my $self = shift;
	return unless $self-> {taken};

	unless (@{$self-> {queue}}) {
		warn "$self is free\n" if $DEBUG;
		$self-> {taken} = 0;
		return;
	}

	my $lambda = shift @{$self-> {queue}};

	warn "$self gives ownership to $lambda\n" if $DEBUG;
	$lambda-> terminate(undef);
}

sub DESTROY { $_-> terminate('dead') for @{shift-> {queue}} }

sub mutex(&)
{
	my ( $self, $timeout) = context;
	$self-> waiter($timeout)-> condition(shift, \&mutex, 'mutex')
}


1;

=pod

=head1 NAME

IO::Lambda::Mutex - wait for a shared resource

=head1 DESCRIPTION

Objects of class C<IO::Lambda::Mutex> are mutexes, that as normal mutexes,
can be taken and released. The mutexes allow lambdas to wait for their
availability with method C<waiter>, that creates and returns a new lambda,
that in turn will finish as soon as the caller can acquire the mutex.

=head1 SYNOPSIS

    use IO::Lambda qw(:lambda);
    use IO::Lambda::Mutex qw(mutex);
    
    my $mutex = IO::Lambda::Mutex-> new;
    
    # wait for mutex that shall be available immediately
    my $waiter = $mutex-> waiter;
    my $error = $waiter-> wait;
    die "error:$error" if $error;
    
    # create and start a lambda that sleep 2 seconds and then releases the mutex
    my $sleeper = lambda {
        context 2;
        timeout { $mutex-> release }
    };
    $sleeper-> start;
    
    # Create a new lambda that shall only wait for 0.5 seconds.
    # It will surely fail.
    lambda {
        context $mutex-> waiter(0.5);
        tail {
            my $error = shift;
            print $error ? "error:$error\n" : "ok\n";
            # $error is expected to be 'timeout'
        }
    }-> wait;

    # Again, wait for the same mutex but using different syntax.
    # This time should be ok.
    lambda {
        context $mutex, 3;
	mutex {
            my $error = shift;
            print $error ? "error:$error\n" : "ok\n";
            # expected to be 'ok'
	}
    }->wait;
    

=head1 API

=over

=item new

The constructor creates a new free mutex.

=item is_free

Returns boolean flag whether the mutex is free or not.
Opposite of L<is_taken>.

=item is_taken

Returns boolean flag whether the mutex is taken or not
Opposite of L<is_free>.

=item take

Attempts to take the mutex. If the mutex is free, the operation
is successful and true value is returned. Otherwise, the operation
is failed and false value is returned.

=item release

Releases the taken mutex. The next waiter lambda in the queue, if available,
is made finished. If there are no waiters in the queue, the mutex is set free,

=item waiter($timeout = undef) :: () -> error

Creates a new lambda, that is finished when the mutex becomes available.
The lambda is inserted into the internal waiting queue. It takes as
many calls to C<release> as many lambdas are in queue, until the mutex
becomes free. The lambda returns an error flags, which is C<undef> if
the mutex was acquired successfully, or the error string.

If C<$timeout> is defined, and by the time it is expired the mutex
could not be obtained, the lambda is removed from the queue, and
returned error value is 'timeout'.

=item remove($lambda)

Removes the lambda created previously by waiter() from internal queue.  Note
that after that operation the lambda will never finish by itself, therefore
this call must be either appended or replaced with C<< $lambda-> terminate >>.

=item mutex($mutex, $timeout = undef) -> error

Condition wrapper over C<waiter>.

=back

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
