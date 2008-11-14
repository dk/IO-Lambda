# $Id: Poll.pm,v 1.2 2008/11/14 20:13:56 dk Exp $
package IO::Lambda::Loop::Poll;
use vars qw(
	@ISA @EXPORT_OK %EXPORT_TAGS 
	$DEBUG @RECORDS @TIMER $TIMER_ACTIVE $MASTER
);

$DEBUG = $IO::Lambda::DEBUG{poll} || 0;
@ISA = qw(Exporter);
@EXPORT_OK  = qw(poll_event poll_cancel);
%EXPORT_TAGS = ( all => \@EXPORT_OK);

use strict;
use warnings;
use Time::HiRes qw(time);
use IO::Lambda qw(:all :dev set_frame get_frame);

$MASTER = bless {}, __PACKAGE__;

# register yield handler
IO::Lambda::add_loop($MASTER);
END {
	@RECORDS = ();
	IO::Lambda::remove_loop($MASTER);
};

# There'll also be a single timer as we need timeouts
$TIMER[WATCH_OBJ] = bless {}, "IO::Lambda::Loop::Poll::Timer";
sub IO::Lambda::Loop::Poll::Timer::io_handler
{
	warn "poll.timer < expired\n" if $DEBUG;
	$TIMER_ACTIVE = 0;
}

sub empty { 0 == @RECORDS }

sub remove
{
	my $lambda = shift;
	my $n = @RECORDS;
	@RECORDS = grep { $_-> {this} ne $lambda } @RECORDS;
	return if $n == @RECORDS;
	warn "poll.remove $lambda\n" if $DEBUG;
	reset_timer();
}

sub yield
{
	warn "poll.yield\n" if $DEBUG > 1;
	my $time = time;

	my @new;
	my @frame = get_frame;
	for my $rec ( @RECORDS) {
		my ( $ok, @result) = $rec-> {poller}-> (
			defined($rec->{deadline}) && $rec->{deadline} <= $time,
			@{ $rec-> {param}}
		);
		unless ($ok) {
			push @new, $rec;
			next;
		}
		warn "poll.resolve($rec)\n" if $DEBUG;
		my $this = $rec-> {this};
		$this-> set_frame($rec-> {method}, $rec->{callback}, @{ $rec->{context} });
		$this-> callout( $rec-> {callback}, @result);
		$this-> resolve( $rec-> {bind});
	}
	set_frame(@frame);
	return if @RECORDS == @new;

	@RECORDS = @new;
	reset_timer();
}

sub reset_timer
{
	my ( $expires, $frequency);
	for my $rec (@RECORDS) {
		my ($f,$d) = @{$rec}{qw(frequency deadline)};
		$frequency = $f if not defined($frequency) or (defined($f) and $frequency > $f);
		$expires   = $d if not defined($expires)   or (defined($d) and $expires   > $d); 
	}

	if ( defined $frequency) {
		$frequency += time;
		if ( defined $expires) {
			$expires = $frequency if $expires > $frequency;
		} elsif ( @RECORDS) {
			$expires = $frequency;
		}
	}

	if ( defined $expires) {
		if ( $TIMER_ACTIVE) {
			if ( abs( $expires - $TIMER[WATCH_DEADLINE]) > 0.001) {
				# restart the active timer
				warn "poll.timer > restart $expires/$TIMER[WATCH_DEADLINE]\n"
					if $DEBUG;
				$IO::Lambda::LOOP-> remove_event( \@TIMER);
				$TIMER[WATCH_DEADLINE] = $expires;
				$IO::Lambda::LOOP-> after( \@TIMER);
			}
			# else, same timeout, on already active timer - do nothing
		} else {
			# resubmit
			warn "poll.timer > submit $expires\n" if $DEBUG;
			$TIMER[WATCH_DEADLINE] = $expires;
			$IO::Lambda::LOOP-> after( \@TIMER);
			$TIMER_ACTIVE = 1;
		}
	} elsif ( $TIMER_ACTIVE) {
		warn "poll.timer > stop\n" if $DEBUG;
		# stop timer
		$IO::Lambda::LOOP-> remove_event( \@TIMER);
		$TIMER_ACTIVE = 0;
	}
}

sub poll_event
{
	my ( $cb, $method, $poller, $deadline, $frequency, @param ) = @_;

	$deadline += time if defined($deadline) and $deadline < 1_000_000_000;
	
	push @RECORDS, {
		this      => this,
		bind      => this-> bind,
		method    => $method,
		callback  => $cb,
		context   => [ context ],
		poller    => $poller,
		deadline  => $deadline,
		param     => \@param,
		frequency => $frequency,
	};

	reset_timer;
	warn "poll.new($RECORDS[-1])\n" if $DEBUG;

	return $RECORDS[-1];
}

# don't call this, use lambda-> cancel_event( $record->{bind} )
sub poll_cancel
{
	my $rec = shift;
	my $n = @RECORDS;
	@RECORDS = grep { $rec != $_ } @RECORDS;
	return if $n == @RECORDS;
	warn "poll.cancel($rec)\n" if $DEBUG;
	reset_timer;
}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::Loop::Poll - emulate asynchronous behavior by polling

=head1 DESCRIPTION

The module can wrap functions, that can only be used in the polling mode, and
provides a layer between them and the lambda framework.

=head1 SYNOPSIS

    use IO::Lambda qw(:all :dev);
    use IO::Lambda::Loop::Poll qw(poll_event);

    sub check_status(&)
    {
        return this-> override_handler('check_status', \&check_status, shift)
            if this-> {override}->{check_status};
        
        my $cb = _subname check_status => shift;
        my ($status_entity, $deadline, @some_params) = context;
        
        poll_event( $cb, \&check_status, \&poll_status, $deadline, $status_entity, @some_params);
    }

    sub poll_status
    {
        my ( $expired, $status_entity, @some_params) = @_;

	# poll, and return more info (in free form) to the callback on success
	return 1, MyLibrary::some_status if MyLibrary::check($status_entity);

	# return timeout flag to the callback (again, in free form)
	return 1, undef if $expired;             

	# nothing happened yet
	return 0;
    }

=head1 API

=over

=item poll_event $callback, $method, $poller, $deadline, $frequency, @param

Registers a polling event on the current lambda. C<$poller> will be called with
first parameter as the expiration flag, so it will be up to the porgrammer how
to respond if both polling succeeded and timeout occured. C<$poller> must
return first parameter the success flag, which means, if true, that the event
must not be watched anymore, and the associated lambda must be notified of the
event. Other parameters are passed to C<$callback>, in free form, according to
the API that the caller of C<poll_event> implements.

C<$frequency> sets up the polling frequency. If undef, then polling occurs
during idle time, when other events are passing.

Returns the newly created event record.

=item poll_cancel $rec

Brutally removes the polling record from the watching queue. For
the graceful remove, use one of the following:

    $lambda-> cancel_event( $rec-> {bind} )

or

    $lambda-> cancel_all_events;

=back

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
