# $Id: HTTPS.pm,v 1.8 2008/01/09 11:47:18 dk Exp $
package IO::Lambda::HTTPS;

use strict;
use warnings;
use Socket;
use IO::Socket::SSL;
use IO::Lambda qw(:all);

sub handle_read
{
	my ( $self, $sock, $buf) = @_;
	my $n = sysread( $sock, $$buf, 32768, length($$buf));
	return if not defined $n and $SSL_ERROR == SSL_WANT_READ;
	return "read error:$!" unless defined $n;

	return $self-> parse($buf) if $self-> got_content($buf);
	return if $n;
	return $self-> parse($buf);
}

# execute a single https request over an established connection
sub https_protocol
{
	my ( $self, $req, $sock, $cached) = @_;

	lambda {
		unless ( $cached) {
			# upgrade socket
			IO::Socket::SSL-> start_SSL( $sock, SSL_startHandshake => 0 );

			# XXX Warning, this'll block because IO::Socket::SSL doesn't 
			# work with non-blocking connects. And I don't really want to 
			# rewrite the SSL handshake myself.
			$sock-> blocking(1);
			my $r = $sock-> connect_SSL;
			$sock-> blocking(0);

			return "SSL connect error: " . ( defined($SSL_ERROR) ? $SSL_ERROR : $!)
				unless $r;
		}

		unless ( print $sock $req-> as_string) {
			return again if $SSL_ERROR == SSL_WANT_WRITE;
			return "write error:$!";
		}

		my $buf = '';

		# OpenSSL does some internal buffering so SSL_read does not always
		# return data even if socket is selected for reading
		my $ret = handle_read( $self, $sock, \$buf);
		return $ret if defined $ret;

		context $sock, $self-> {deadline};
	read {
		return 'timeout' unless shift;

		my $ret = handle_read( $self, $sock, \$buf);
		return defined($ret) ? $ret : again;
	}};
}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::HTTPS - https requests lambda style

=head1 DESCRIPTION

The module is used internally by L<IO::Lambda::HTTP> and is a separate module
for installations where underlying C<IO::Socket::SSL> and C<Net::SSLeay> modules
are not installed. The module is not to be used directly.

=head1 SEE ALSO

L<IO::Lambda::HTTP>

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
