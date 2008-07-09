# $Id: tcp-lambda.pl,v 1.1 2008/07/09 09:00:47 dk Exp $
# An echo client-server benchmark
use strict;
use IO::Lambda qw(:all);
use Time::HiRes qw(time);
use IO::Handle;
use IO::Socket::INET;

require IO::Lambda::Loop::AnyEvent if @ARGV and $ARGV[0] eq '--anyevent';

my $CYCLES = 500;

# benchmark in lambdas

my $port      = $ENV{TESTPORT} || 29876;
my $serv_sock = IO::Socket::INET-> new(
	Listen    => 5,
	LocalPort => $port,
	Proto     => 'tcp',
	ReuseAddr => 1,
);
die "listen() error: $!\n" unless $serv_sock;

sub session
{ 
	my $conn = shift;
	lambda {
		context getline(), $conn;
	tail {
		my $s = shift;
		return unless defined $s;
		print $conn $s;
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
			close $conn;
		};
	};
};
$server-> start;

# prepare connection to the server
sub sock
{
	my $x = IO::Socket::INET-> new(
		PeerAddr  => 'localhost',
		PeerPort  => $port,
		Proto     => 'tcp',
	);
	$x-> autoflush(1);
	die "connect() error: $!\n" unless $x;
	return $x;
}

my $t = time;
for my $id ( 1..$CYCLES) {
	this lambda {
		my $sock = sock;
		context $sock;
		write {
			print $sock "can write $id\n";
		read {
			close $sock;
		}};
	};
	this-> wait;
}
$t = time - $t;
printf "%.3f sec\n", $t;
$server-> destroy;
