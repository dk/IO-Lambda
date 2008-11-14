# $Id: Flock.pm,v 1.1 2008/11/14 15:06:24 dk Exp $
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

	my $cb = _subname lock => shift;
	my ($fh, $deadline, $shared) = context;

	poll_event( $cb, \&lock, \&poll_flock, $deadline, $fh, $shared);
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

=item flock($filehandle, $deadline, $shared) -> ($lock_obtained = 1 | $timeout = 0)

Waits for lock to be obtained, or expired. If succeeds, the (shared or
exclusive) lock is already obtained by C<flock($filehandle, LOCK_NB)> call.

=back

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
