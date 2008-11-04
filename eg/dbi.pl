#$Id: dbi.pl,v 1.5 2008/11/04 19:04:08 dk Exp $
use strict;
use warnings;

use IO::Lambda qw(:all);
use IO::Lambda::DBI;
use IO::Lambda::Thread qw(threaded);

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

my $t = threaded {
	my $socket = shift;
	IO::Lambda::Message::DBI-> new( $socket, $socket )-> run;
};

$t-> start;
$t-> join_on_read(0);

my $dbi = IO::Lambda::DBI-> new( $t-> socket, $t-> socket );
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

undef $dbi;

$t-> join_on_read(1);
$t-> join;
