# $Id: Mutex.pm,v 1.3 2009/01/16 15:05:56 dk Exp $
package IO::Lambda::Mutex;
use vars qw($DEBUG @ISA);
$DEBUG = $IO::Lambda::DEBUG{mutex} || 0;

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
	push @{$self-> {queue}}, $waiter, $waiter-> bind;

	if ( defined $timeout) {
		my $l = $waiter;
		$waiter = lambda {
			context $timeout, $l;
		any_tail {
			if ($_[0]) { # acquired the mutex!
				warn "$self acquired for $l\n" if $DEBUG;
				return undef;
			}
				
			warn "$self timeout for $l\n" if $DEBUG;
			
			# remove the lambda from queue
			my $found;
			my $q = $self-> {queue};
			for ( my $i = 0; $i < @$q; $i += 2) {
				next if $q->[$i] != $l;
				$found = $i;
				last;
			}
			if ( defined $found) {
				my ( $lambda, $bind) = splice( @$q, $found, 2);
				$lambda-> resolve($bind);
			} else {
				warn "$self failed to remove $l from queue\n" if $DEBUG;
			}

			return 'timeout';
		}};
	}

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
	my $bind   = shift @{$self-> {queue}};
	$lambda-> callout(undef, undef);
	warn "$self gives ownership to $lambda\n" if $DEBUG;
	$lambda-> resolve($bind);
}

sub DESTROY
{
	my $self = shift;
	my $q = $self-> {queue};
	while ( @$q) {
		my $lambda = shift @$q;
		my $bind   = shift @$q;
		$lambda-> callout(undef, 'dead');
		$lambda-> resolve($bind);
	}
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
    use IO::Lambda::Mutex;
    
    my $mutex = IO::Lambda::Mutex-> new;
    # new mutex is free, take it immediately
    $mutex-> take;
    
    # wait for mutex that shall be available immediately
    my $waiter = $mutex-> waiter;
    my $error = $waiter-> wait;
    die "error:$error" if $error;
    
    # create and start a lambda that sleep 2 seconds and then releases the mutex
    lambda {
        context 2;
        timeout { $mutex-> release }
    }-> start;
    
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

=back

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
