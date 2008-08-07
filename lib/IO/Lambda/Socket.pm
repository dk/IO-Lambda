# $Id: Socket.pm,v 1.3 2008/08/07 12:58:34 dk Exp $
use strict;
use warnings;

package IO::Lambda::Socket;
use Carp qw(croak);
use Socket;
use Exporter;
use IO::Lambda qw(:all);
use Time::HiRes qw(time);
use vars       qw(@ISA @EXPORT_OK %EXPORT_TAGS);
@ISA         = qw(Exporter);
%EXPORT_TAGS = (all => \@EXPORT_OK);
@EXPORT_OK   = qw(connect accept send recv);
use subs       qw(connect accept send recv);

sub connect(&)
{
	return this-> override_handler('connect', \&connect, shift)
		if this-> {override}->{connect};

	my $cb = shift;
	my ($socket, $deadline) = context;

	return this-> add_constant( $cb, \&connect, "Bad socket") unless $socket;

	this-> watch_io(
		IO_WRITE, $socket, $deadline,
		sub {
			shift-> set_frame( \&connect, $cb, $socket, $deadline);

			my @param;
			unless ( $_[0]) {
				@param = ('timeout');
			} else {
				$! = unpack('i', getsockopt( $socket, SOL_SOCKET, SO_ERROR));
				@param = ($!) if $!;
			}
			$cb ? $cb-> (@param) : @param;
		}
	);
}

sub accept(&)
{
	return this-> override_handler('accept', \&accept, shift)
		if this-> {override}->{accept};

	my $cb = shift;
	my ($socket, $deadline) = context;

	return this-> add_constant( $cb, \&connect, "Bad socket") unless $socket;

	this-> watch_io(
		IO_READ, $socket, $deadline,
		sub {
			shift-> set_frame( \&accept, $cb, $socket, $deadline);

			my @param;
			unless ( $_[0]) {
				@param = ('timeout');
			} else {
				my $h = IO::Handle-> new;
				@param = ( 
					CORE::accept( $h, $socket) ?
					($h) : ($!)
				);
			}
			$cb ? $cb-> (@param) : @param;
		}
	);
}

# recv() :: ($fh, $length, $flags, $deadline) -> (address,msg|undef,error)
sub recv(&)
{
	return this-> override_handler('recv', \&recv, shift)
		if this-> {override}->{recv};

	my $cb = shift;
	my ($socket, $length, $flags, $deadline) = context;

	return this-> add_constant( $cb, \&recv, undef, "Bad socket")
		unless $socket;

	this-> watch_io(
		IO_READ, $socket, $deadline,
		sub {
			shift-> set_frame( \&recv, $cb, $socket, $length, $flags, $deadline);

			my @param;
			unless ( $_[0]) {
				@param = ('timeout');
			} else {
				my $buf = '';
				my $r = CORE::recv( 
					$socket, $buf, $length, 
					$flags || 0
				);
				if ( defined($r)) {
					@param = defined($r) ? ($r,$buf) : (undef,$!);
				} else {
					@param = ( undef, $!);
				}
			}
			$cb ? $cb-> (@param) : @param;
		}
	);
}

# send() :: ($fh, $msg, $flags, $to, $deadline) -> ioresult
sub send(&)
{
	return this-> override_handler('send', \&send, shift)
		if this-> {override}->{send};

	my $cb = shift;
	my ($socket, $msg, $flags, $to, $deadline) = context;

	return this-> add_constant( $cb, \&send, undef, "Bad socket")
		unless $socket;

	this-> watch_io(
		IO_WRITE, $socket, $deadline,
		sub {
			shift-> set_frame( \&recv, $cb, $socket, $msg, $flags, $to, $deadline);

			my @param;
			unless ( $_[0]) {
				@param = ('timeout');
			} else {
				$flags ||= 0;
				my $r = defined($to) ? 
					CORE::send($socket, $msg, $flags, $to) :
					CORE::send($socket, $msg, $flags);
				@param = defined($r) ? ($r) : (undef,$!);
			}
			$cb ? $cb-> (@param) : @param;
		}
	);
}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::Socket - primitive lambda socket wrappers

=head1 DESCRIPTION

This module provides a set of convenient wrappers for sockets as sources of I/O
events. The module doesn't account for much lower-lever socket machinery, the
programmer is expected to create non-blocking sockets by himself, preferably
use C<IO::Socket> module.

=head1 SYNOPSIS

	use IO::Socket;
	use IO::Lambda qw(:all);
	use IO::Lambda::Socket qw(:all);

TCP

	my $server = IO::Socket::INET-> new(
		Listen    => 5,
		LocalPort => 10000,
		Blocking  => 0,
		ReuseAddr => 1,
	);
	die $! unless $server;

	my $serv = lambda {
		context $server;
		accept {
			my $conn = shift;
			die "error:$conn\n" unless ref($conn);
			again;
			context getline, $conn, \(my $buf = '');
		tail {
			next unless defined $_[0];
			print "you said: $_[0]";
			again;
		}}
	};

	sub connector 
	{
		my $id = shift;
		lambda {
			my $client = IO::Socket::INET-> new(
				PeerAddr  => 'localhost',
				PeerPort => 10000,
				Blocking  => 0,
			);
			context $client;
		connect {
			die "error:$_[1]\n" unless $_[0];
			print $client "hello from $id\n";
		}}
	}

	$serv-> wait_for_all( map { connector($_) } 1..5);

UDP

	my $server = IO::Socket::INET-> new(
		LocalPort => 10000,
		Blocking  => 0,
		Proto     => 'udp',
	);
	die $! unless $server;

	my $serv = lambda {
		context $server, 256;
		recv {
			my ($addr, $msg) = @_;
			my ($port, $iaddr) = sockaddr_in($addr);
			my $host = inet_ntoa($iaddr);
			die "error:$msg\n" unless defined $addr;
			print "udp_recv($host:$port): $msg\n";
			again;
		}
	};

	sub connector 
	{
		my $id = shift;
		lambda {
			my $client = IO::Socket::INET-> new(
				PeerAddr  => 'localhost',
				PeerPort  => 10000,
				Proto     => 'udp',
				Blocking  => 0,
			);
			context $client, "hello from $id";
		send {
			die "send error:$_[1]\n" unless $_[0];
		}}
	}

	$serv-> wait_for_all( map { connector($_) } 1..3);

=head1 API

=over

=item accept($socket, $deadline=undef) ->  ($new_socket | undef,$error)

Expects stream C<$socket> in a non-blocking listening state. Executes either
after connection arrives, or after C<$deadline>.  Returns a new socket serving
the new connection on success, C<undef> and an error string on failure. The
error string is either C<timeout> or C<$!>.

See also L<perlfunc/accept>.

=item connect($socket, $deadline=undef) -> (1 | undef,$error)

Expects stream C<$socket> in a non-blocking connect state. Executes either
after connection succeeds, or after C<$deadline>.  Returns true constant (C<1>)
on success, C<undef> and an error string on failure. The error string is either
C<timeout> or C<$!>.

See also L<perlfunc/connect>.

=item recv($socket, $length, $flags=0, $deadline=undef) -> ($addr,$msg | undef,$error)

Expects a non-blocking datagram C<$socket>. After the socket becomes readable,
tries to read C<$length> bytes using C<CORE::recv> call. Returns packed address
and received message on success. Returns C<undef> and an error string on
failure. The error string is either C<timeout> or C<$!>.

See also L<perlfunc/recv>.

=item send($socket, $msg, $flags, $to=undef, $deadline=undef) -> ($nbytes | undef,$error)

Expects a non-blocking datagram C<$socket>. After the socket becomes writable,
tries to write C<$msg> using C<CORE::send> call. Depending whether C<$to> is
defined or not, 4- or 3- parameter versions of C<CORE::send> are used. Returns
number of bytes sent address and received message on success. On failure
returns C<undef> and an error string. The error string is either C<timeout> or
C<$!>.

See also L<perlfunc/send>.

=back

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2008 capmon ApS. All rights reserved.

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
