# $Id: snmp.pl,v 1.2 2008/01/25 13:46:04 dk Exp $
use strict;
use SNMP;
use IO::Lambda::SNMP qw(:all);
use IO::Lambda qw(:lambda);

my $sess = SNMP::Session-> new(
	DestHost => 'localhost',
	Community => 'public',
	Version   => '2c',
);

this lambda {
	context $sess, new SNMP::Varbind;
	snmpgetnext {
		my $vb = shift;
		print @{$vb->[0]}, "\n" ; 
		context $sess, $vb;
		again unless $sess-> {ErrorNum};
	};
};
this-> wait;
