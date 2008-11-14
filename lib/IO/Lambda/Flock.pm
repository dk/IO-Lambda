# $Id: Flock.pm,v 1.3 2008/11/14 20:18:26 dk Exp $
package IO::Lambda::Flock;
use vars qw($DEBUG @ISA @EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT_OK   = qw(flock);
%EXPORT_TAGS = ( all => \@EXPORT_OK);
$DEBUG = $IO::Lambda::DEBUG{flock} || 0;

use strict;
use warnings;
use Fcntl ':flock';
use IO::Lambda qw(:all :dev);
use IO::Lambda::Loop::Poll qw(poll_event);

sub poll_flock
{
	my ( $expired, $fh, $shared) = @_;
	if ( CORE::flock( $fh, LOCK_NB | ($shared ? LOCK_SH : LOCK_EX) )) {
		warn "flock $fh obtained\n" if $DEBUG;
		return 1, 1;
	}
	return 1, 0 if $expired;
	return 0;
}

sub flock(&)
{
	return this-> override_handler('flock', \&flock, shift)
		if this-> {override}->{flock};

	my $cb = _subname flock => shift;
	my ($fh, %opt) = context;
	my $deadline = exists($opt{timeout}) ? $opt{timeout} : $opt{deadline};

	poll_event(
		$cb, \&lock, \&poll_flock, 
		$deadline, $opt{frequency}, 
		$fh, $opt{shared}
	);
}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::FLock - lambda-style file locking

=head1 DESCRIPTION

The module implements a non-blocking flock(2) wrapper by polling

=head1 SYNOPSIS

=head1 API

=over

=item flock($filehandle, %options) -> ($lock_obtained = 1 | $timeout = 0)

Waits for lock to be obtained, or expired. If succeeds, the (shared or
exclusive) lock is already obtained by C<flock($filehandle, LOCK_NB)> call.
Options:

=over

=item C<timeout> or C<deadline>

These two options are synonyms, both declare when the waiting for the lock
should give up. If undef, timeout never occurs.

=item shared

If set, C<LOCK_SH> is used, otherwise C<LOCK_EX>.

=item frequency

Defines how often the polling for lock release should occur. If left undefined,
polling occurs in idle time, when the other events are dispatched.

=back

=back

=head1 SEE ALSO

L<Fcntl>, L<IO::Lambda::Loop::Poll>.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
