#! /usr/bin/perl
# $Id: 04_tcp.t,v 1.1 2007/12/11 14:48:38 dk Exp $

use strict;
use warnings;
use Test::More tests => 6;
use IO::Lambda qw(:all);
use IO::Handle;
use IO::Socket::INET;

my $port      = $ENV{TESTPORT} || 29876;
my $server    = IO::Lambda-> new;
my $serv_sock = IO::Socket::INET-> new(
	Listen    => 5,
	LocalPort => $port,
	Proto     => 'tcp',
	Blocking  => 0,
	ReuseAddr => 1,
);
die "listen() error: $!\n" unless $serv_sock;
my $last_session_response = '';

self_context($server, $serv_sock);
read {
	my $conn = IO::Handle-> new;
	my $q    = IO::Lambda-> new;
	accept( $conn, $serv_sock) or die "accept() error:$!";
	$conn-> autoflush(1);
	again;

	my $buf = '';
	self_context( $q, $conn, time + 1);
	read {
		unless ( shift) {
			print $conn "timeout\n";
			return 'timed out';
		}
		my $n = sysread( $conn, $buf, 16384, length($buf));
		return "sysread error:$!" unless defined $n;
		return "closed remotely" unless $n;
		print $conn "read $n bytes\n";
		if ( length($buf) > 128) {
			print $conn "enough\n";
			return 'got fed up';
		} 
		again;
	};
	finally {
		$last_session_response = shift;
		close $conn;
	};
};
ok( $server-> loop, 'server is alive' );

# prepare connection to the server
my ( $client, $c);

sub sock
{
	my $x = IO::Socket::INET-> new(
		PeerAddr  => 'localhost',
		PeerPort  => $port,
		Proto     => 'tcp',
		Blocking  => 0,
	);
	die "connect() error: $!\n" unless $x;
	return $x;
}

sub init
{
	$client = IO::Lambda-> new;
	$c      = sock();
	self_context( $client, $c);
}

# test that connection works at all
init;
write   { "can write" };
finally { ok('can write' eq shift, 'got write'); };
$client-> wait;

# test that we can write and can read response
init;
write {
	print $c "moo";
	read {
		$_ = <$c>;
		chomp;
		return $_;
	}
};
finally { ok('read 3 bytes' eq shift, 'got echo'); };
$client-> wait;

## test that we can do the same in parallel
init;
my $c2 = sock;
write {
	self_context( $client, $c2);
write {
	print $c  "moo1";
	print $c2 "moo2";
	read {
		my $resp = <$c2>;
		chomp $resp;
		close $c2;
		self_context( $client, $c);
	read {
		$_ = <$c>;
		chomp $_;
		return ($resp,$_);
	}};
}};
finally { ok((( $_[0] eq $_[1]) and ($_[0] eq 'read 4 bytes')), 'parallel connection'); };
$client-> wait;

# test that we can do the same parallel stunt with two lambda objects
# and finally(!) abstract the protocol from objects
init;
$c2 = sock;
my $client2 = IO::Lambda-> new;

sub protocol
{
	my ( $lambda, $socket, $what) = @_;
	self_context( $lambda, $socket);
	write {
		print $socket $what;
		read {
			my $resp = <$socket>;
			chomp $resp;
			close $socket;
			return $resp;
		};
	};
}

protocol( $client,  $c,  'mumbo');
protocol( $client2, $c2, 'jumbo');
IO::Lambda::wait_for_all( $client, $client2);
my @r = map { $_-> peek } ( $client, $client2);
ok((( $r[0] eq $r[1]) and ($r[0] eq 'read 5 bytes')), 'two lambdas');

# finally test the timeout
init;
write {
	self_context( $client, time + 2);
	sleep {
		context($c);
		read {
			my $resp = <$c>;
			chomp $resp;
			close $c;
			return $resp;
		};
	};
};
finally { ok( shift eq 'timeout', 'timeout'); };
$client-> wait;
