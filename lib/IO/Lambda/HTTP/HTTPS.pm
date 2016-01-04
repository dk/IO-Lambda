# $Id: HTTPS.pm,v 1.14 2012/03/13 03:23:24 dk Exp $
package IO::Lambda::HTTP::HTTPS;

use strict;
use warnings;
use Socket;
use IO::Socket::SSL;
use IO::Lambda qw(:lambda :stream :dev :constants);
use Errno qw(EWOULDBLOCK EAGAIN);

our $DEBUG = $IO::Lambda::DEBUG{https};

# check for SSL error condition, wait for read or write if necessary
# return ioresult
sub https_wrapper
{
	my ($sock, $deadline) = @_;
	tail {
		my ( $bytes, $error) = @_;
		warn 
			"SSL on fh(", fileno($sock), ") = ",
			(defined($bytes) ? "$bytes bytes" : "error $error"),
			"\n" if $DEBUG;
		return $bytes if defined $bytes;
		return undef, $error if $error eq 'timeout';

		if ( $error == SSL_WANT_READ) {
			warn "SSL_WANT_READ on fh(", fileno($sock), ")\n" if $DEBUG;
			my @ctx = context;
			context $sock, $deadline;
			readable { 
				return 'timeout' unless shift;
				context @ctx;
				https_wrapper($sock, $deadline)
			}
		} elsif ( $error == SSL_WANT_WRITE) {
			warn "SSL_WANT_WRITE on fh(", fileno($sock), ")\n" if $DEBUG;
			my @ctx = context;
			context $sock, $deadline;
			writable { 
				return 'timeout' unless shift;
				context @ctx;
				https_wrapper($sock, $deadline)
			}
		} else {
			warn 
				"SSL retry on fh(", fileno($sock), ") = ",
				(defined($bytes) ? "$bytes bytes" : "error $error"),
				"\n" if $DEBUG;
			return $bytes, $error;
		}
	}
}

sub https_connect
{
	my ($sock, $deadline) = @_;
	IO::Socket::SSL-> start_SSL( $sock, SSL_startHandshake => 0 );

	lambda {
		# emulate sysreader/syswriter to be able to 
		# reuse https_wrapper
		context lambda { $sock-> connect_SSL ? 1 : (undef, $SSL_ERROR) };
		https_wrapper( $sock, $deadline );
	}
}

sub https_syswriter (){ lambda
{
	my ( $fh, $buf, $length, $offset, $deadline) = @_;

	this-> watch_io( IO_WRITE, $fh, $deadline, _subname https_syswriter => sub {
		return undef, 'timeout' unless $_[1];
                local $SIG{PIPE} = 'IGNORE';
		my $n = syswrite( $fh, $$buf, $length, $offset);
		my $err = $!;
		$err = $SSL_ERROR if $err == EWOULDBLOCK || $err == EAGAIN;
		if ( $DEBUG) {
			warn "fh(", fileno($fh), ") wrote ", ( defined($n) ? "$n bytes out of $length" : "error $err"), "\n";
			warn substr( $$buf, $offset, $n), "\n" if $DEBUG > 1 and ($n || 0) > 0;
		}
		return undef, $err unless defined $n;
		return $n;
	});
}}

sub https_writer
{
	my $cached = shift;
	my $writer = https_syswriter;

	lambda {
		my ( $sock, $req, $length, $offset, $deadline) = @_;
		if ( $cached ) {
			context $writer, $sock, $req, $length, $offset, $deadline;
			return https_wrapper($sock, $deadline);
		}
		context https_connect($sock, $deadline);
	tail {
		my ( $bytes, $error) = @_;
		return @_ if defined $error;

		context $writer, $sock, $req, $length, $offset, $deadline;
		https_wrapper($sock, $deadline);
	}}
}

sub https_sysreader (){ lambda 
{
	my ( $fh, $buf, $length, $deadline) = @_;
	$$buf = '' unless defined $$buf;

	this-> watch_io( IO_READ, $fh, $deadline, _subname https_sysreader => sub {
		return undef, 'timeout' unless $_[1];
                local $SIG{PIPE} = 'IGNORE';
		my $n = sysread( $fh, $$buf, $length, length($$buf));
		my $err = $!;
		$err = $SSL_ERROR if $err == EWOULDBLOCK || $err == EAGAIN;
		if ( $DEBUG ) {
			warn "fh(", fileno($fh), ") read ", ( defined($n) ? "$n bytes" : "error $err"), "\n";
			warn substr( $$buf, length($$buf) - $n), "\n" if $DEBUG > 1 and ($n || 0) > 0;
		}
		return undef, $err unless defined $n;
		return $n;
	})
}}

sub https_reader
{
	my $reader = https_sysreader;
	lambda {
		my ( $sock, $buf, $length, $deadline) = @_;
		context $reader, $sock, $buf, $length, $deadline;
		https_wrapper($sock, $deadline);
	}
}


1;

__DATA__

=pod

=head1 NAME

IO::Lambda::HTTP::HTTPS - https requests lambda style

=head1 DESCRIPTION

The module is used internally by L<IO::Lambda::HTTP>, and is a separate module
for the sake of installations that contain C<IO::Socket::SSL> and
C<Net::SSLeay> prerequisite modules.  The module is not to be used directly.

=head1 SEE ALSO

L<IO::Lambda::HTTP>

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
