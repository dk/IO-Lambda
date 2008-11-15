# $Id: HTTPS.pm,v 1.11 2008/11/15 22:09:34 dk Exp $
package IO::Lambda::HTTP::HTTPS;

use strict;
use warnings;
use Socket;
use IO::Socket::SSL;
use IO::Lambda qw(:lambda :stream);

our $DEBUG = $IO::Lambda::DEBUG{https};

sub https_wrapper
{
	my $sock = shift;
	tail {
		my ( $bytes, $error) = @_;
		warn 
			"SSL on fh(", fileno($sock), ") = ",
			(defined($bytes) ? "$bytes bytes" : "error $error"),
			"\n" if $DEBUG;
		return $bytes if defined $bytes;
		return $error if $error eq 'timeout';
	
		my $v = '';
		vec( $v, fileno($sock), 1) = 1;
		if ( $SSL_ERROR == SSL_WANT_READ) {
			warn "SSL_WANT_READ on fh(", fileno($sock), ")\n" if $DEBUG;
			select( $v, undef, undef, 0);
			return again;
		} elsif ( $SSL_ERROR == SSL_WANT_WRITE) {
			warn "SSL_WANT_WRITE on fh(", fileno($sock), ")\n" if $DEBUG;
			select( undef, $v, undef, 0);
			return again;
		} else {
			warn 
				"SSL retry on fh(", fileno($sock), ") = ",
				(defined($bytes) ? "$bytes bytes" : "error $error"),
				"\n" if $DEBUG;
			return $bytes, $error;
		}
	}
}


sub https_writer
{
	my $cached = shift;
	my $writer = syswriter;

	lambda {
		my ( $sock, $req, $length, $offset, $deadline) = @_;

		# upgrade the socket
		unless ( $cached) {
			warn "negotiating SSL on fileno(", fileno($sock), ")\n" if $DEBUG;
			IO::Socket::SSL-> start_SSL( $sock, SSL_startHandshake => 0 );
			# XXX Warning, this'll block because IO::Socket::SSL doesn't 
			# work with non-blocking connects. And I don't really want to 
			# rewrite the SSL handshake myself.
			$sock-> blocking(1);
			my $r = $sock-> connect_SSL;
			$sock-> blocking(0);

			return undef, "SSL connect error: " . ( defined($SSL_ERROR) ? $SSL_ERROR : $!)
				unless $r;
			$cached = 1;
			warn "SSL enabled on fileno(", fileno($sock), ")\n" if $DEBUG;
		}

		context $writer, $sock, $req, $length, $offset, $deadline;
		https_wrapper($sock);
	}
}

sub https_reader
{
	my $reader = sysreader;
	lambda {
		my ( $sock, $buf, $length, $deadline) = @_;
		context $reader, $sock, $buf, $length, $deadline;
		https_wrapper($sock);
	}
}


1;

__DATA__

=pod

=head1 NAME

IO::Lambda::HTTP::HTTPS - https requests lambda style

=head1 DESCRIPTION

The module is used internally by L<IO::Lambda::HTTP> and is a separate module
for installations where underlying C<IO::Socket::SSL> and C<Net::SSLeay> modules
are installed. The module is not to be used directly.

=head1 SEE ALSO

L<IO::Lambda::HTTP>

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
