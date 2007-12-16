# $Id: snmp.pl,v 1.1 2007/12/16 17:18:57 dk Exp $
use strict;
use SNMP;
use IO::Lambda::SNMP qw(:all);
use IO::Lambda qw(:all);

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
