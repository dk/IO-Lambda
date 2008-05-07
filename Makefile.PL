# $Id: Makefile.PL,v 1.3 2008/05/07 19:47:26 dk Exp $
use ExtUtils::MakeMaker;
use IO::Socket::INET;

my $online_tests;
my $s = IO::Socket::INET->new(
	PeerAddr => "www.google.com:80",
	Timeout  => 10,
);
	
if ($s) {
	close($s);
	
	print <<EOT;
	
You appear to be directly connected to the Internet.  I have some tests
that try to query live nameservers.
	
EOT
	
	$online_tests = prompt("Do you want to enable these tests?", "y") =~ /^y/i ? 1 : 0;
}

if ($online_tests) {
	open(ENABLED, ">t/online.enabled") || die "Can't touch ./t/online.enabled $!";
	close(ENABLED)                     || die "Can't touch ./t/online.enabled $!";
}

WriteMakefile(
	NAME          => 'IO::Lambda',
	AUTHOR        => 'Dmitry Karasik <dmitry@karasik.eu.org>',
	ABSTRACT_FROM => 'lib/IO/Lambda.pm',
	VERSION_FROM  => 'lib/IO/Lambda.pm',
	PREREQ_PM     => {
		'Net::DNS'          => 0,
		'LWP'               => 0,
		# 'IO::Socket::SSL' => 0,  # for HTTPS
		# 'SNMP'            => 0,  # for IO::Lambda::SNMP
		# 'AnyEvent'        => 0,  # for alternative event loop
	},
	clean         => { FILES => 't/online.enabled' },
);
