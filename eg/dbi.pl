#$Id: dbi.pl,v 1.2 2008/11/03 22:05:57 dk Exp $

use IO::Lambda qw(:all);
use IO::Lambda::DBI;

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

my $dbi = IO::Lambda::DBI-> new;
lambda {
	context $dbi-> connect('DBI:mysql:database=mysql', '', '');
	tail {
		die @_ unless shift;
		context 
			check_dbi($dbi),
			check_dbi($dbi),
			check_dbi($dbi);
	tails {
		context $dbi-> disconnect;
	&tail();
}}}-> wait;
