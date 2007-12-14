#! /usr/bin/perl
# $Id: 04_tcp.t,v 1.5 2007/12/14 14:42:04 dk Exp $

use strict;
use warnings;
use Test::More tests => 6;
use IO::Lambda qw(:all);
use IO::Handle;
use IO::Socket::INET;

#$IO::Lambda::DEBUG = 2;

my $port      = $ENV{TESTPORT} || 29876;
my $serv_sock = IO::Socket::INET-> new(
	Listen    => 5,
	LocalPort => $port,
	Proto     => 'tcp',
	ReuseAddr => 1,
);
die "listen() error: $!\n" unless $serv_sock;
my $last_session_response = '';

sub session
{ 
	my $conn = shift;
	lambda {
		my $buf  = '';
		context $conn, time + 0.3;
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
	}}
}

my $server = lambda {
	context $serv_sock;
	read {
		my $conn = IO::Handle-> new;

		accept( $conn, $serv_sock) or die "accept() error:$!";
		$conn-> autoflush(1);
		again;

		context session($conn);
		tail {
			$last_session_response = shift;
			close $conn;
		};
	};
};
ok( $server-> is_passive, 'server is created' );

# prepare connection to the server
sub sock
{
	my $x = IO::Socket::INET-> new(
		PeerAddr  => 'localhost',
		PeerPort  => $port,
		Proto     => 'tcp',
	);
	die "connect() error: $!\n" unless $x;
	return $x;
}

# test that connection works at all
this lambda {
	context sock;
	write { "can write" };
};
ok(this-> wait eq 'can write', 'got write');
ok( $server-> is_waiting, 'server is alive' );

# test that we can write and can read response
this lambda {
	my $c = sock;
	context $c;
	write {
		print $c "moo";
		read {
			$_ = <$c>;
			chomp;
			return $_;
		}
	};
};
ok(this-> wait eq 'read 3 bytes', 'got echo');

## test that we can do the same in parallel
sub conn
{
	my $id = shift;
	lambda {
		my $c = sock;
		context $c;
		write {
			print $c "moo$id";
			read {
				$_ = <$c>;
				chomp;
				close $c;
				return $_;
			}
		}
	};
}
this lambda {
	context map { conn $_ } (1,22,333,4444);
	tails { join '+', map { m/(\d+)/ } @_ };
};
ok(this-> wait eq '4+5+6+7', 'parallel connections');

# finally test the timeout
this lambda {
	my $c = sock;
	context $c             and write {
	context time + 0.5     and sleep {
	context $c             and read  {
	my $resp = <$c>;
	chomp $resp;
	close $c;
	return $resp;
}}}};
ok(this-> wait eq 'timeout', 'timeout');
