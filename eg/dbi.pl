#$Id: dbi.pl,v 1.7 2008/11/05 15:04:45 dk Exp $
use strict;
use warnings;

use IO::Socket::INET;
use IO::Lambda qw(:all);
use IO::Lambda::DBI;
use IO::Lambda::Thread qw(threaded);
use IO::Lambda::Fork qw(forked);
use IO::Lambda::Socket;

my $port = 3333;

sub usage
{
	print <<USAGE;

Test implementation of non-blocking DBI. This script can work in several modes,
run with one of the parameters to switch:

   $0 thread      - use DBI calls in a separate thread
   $0 fork        - use DBI calls in a separate process
   $0 remote HOST - connect to host to port $port and request DBI there
   $0 listen      - listen on port $port, execute incoming connections
	
USAGE
	exit;
}

my $mode = shift(@ARGV) || '';
usage unless $mode =~ /^(fork|thread|remote|listen)$/;

sub check_dbi
{
	my $dbi = shift;
	my $tries = 3;
	lambda {
		my $expect = int rand 100;
		context $dbi-> selectrow_array('SELECT 1 + ?', {}, $expect);
	tail {
		return warn(@_) unless shift;
		my $ret = -1 + shift;
		print "$expect -> $ret\n";

		if ( $tries--) {
			this-> start;
		}
	}}
}

sub execute
{
	my $dbi = shift;
	lambda {
		context $dbi-> connect('DBI:mysql:database=mysql', '', '');
		tail {
			warn(@_), return unless shift;
			context 
				check_dbi($dbi),
				check_dbi($dbi),
				check_dbi($dbi);
		tails {
			context $dbi-> disconnect;
		&tail();
	}}}-> wait;
}

# run

if ( $mode eq 'thread') {
	die $IO::Lambda::Thread::DISABLED if $IO::Lambda::Thread::DISABLED;

	my $t = threaded {
		my $socket = shift;
		IO::Lambda::Message::DBI-> new( $socket, $socket )-> run;
	};
	
	$t-> start;
	$t-> join_on_read(0);
	
	my $dbi = IO::Lambda::DBI-> new( $t-> socket, $t-> socket );
	execute($dbi);
	undef $dbi;
	
	$t-> join_on_read(1);
	print $t-> join, "\n";
} elsif ( $mode eq 'fork') {
	my $t = forked {
		my $socket = shift;
		IO::Lambda::Message::DBI-> new( $socket, $socket )-> run;
	};
	
	$t-> start;
	$t-> listen(0);
	
	my $dbi = IO::Lambda::DBI-> new( $t-> socket, $t-> socket );
	execute($dbi);
	undef $dbi;
	
	$t-> listen(1);
	print $t-> wait, "\n";
} elsif ( $mode eq 'remote') {
	my $host = shift @ARGV;
	usage unless defined $host;

	my $s = IO::Socket::INET-> new("$host:$port");
	die $! unless $s;

	my $dbi = IO::Lambda::DBI-> new( $s, $s);
	execute($dbi);

	undef $s;
} elsif ( $mode eq 'listen') {
	my $s = IO::Socket::INET-> new(
		LocalPort => $port,
		Listen    => 5,
	);
	while ( 1) {
		my $c = IO::Handle-> new;
		die $! unless accept( $c, $s);
		my $loop = IO::Lambda::Message::DBI-> new( $c, $c);
		$loop-> run;
		close($c);
	}
}
