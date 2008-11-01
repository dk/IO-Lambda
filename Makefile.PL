# $Id: Makefile.PL,v 1.11 2008/11/01 12:33:37 dk Exp $
use Getopt::Long  qw(GetOptions);
use ExtUtils::MakeMaker;
use IO::Socket::INET;

my $online_tests;

GetOptions(
	'online-tests!' => \$online_tests,
);

unless ( defined $online_tests) {
	my $s = IO::Socket::INET->new(
		PeerAddr => "www.google.com:80",
		Timeout  => 10,
	);
		
	if ($s) {
		close($s);
		
		print <<EOT;
	
You appear to be directly connected to the Internet.  I have some tests
that try to query live nameservers and google.
	
EOT
	
		$online_tests = prompt("Do you want to enable these tests?", "y") =~ /^y/i ? 1 : 0;
	}
}

if ($online_tests) {
	open(ENABLED, ">t/online.enabled") || die "Can't touch ./t/online.enabled $!";
	close(ENABLED)                     || die "Can't touch ./t/online.enabled $!";
} else {
	unlink "t/online.enabled";
}

WriteMakefile(
	NAME          => 'IO::Lambda',
	AUTHOR        => 'Dmitry Karasik <dmitry@karasik.eu.org>',
	ABSTRACT_FROM => 'lib/IO/Lambda.pm',
	VERSION_FROM  => 'lib/IO/Lambda.pm',
	PREREQ_PM     => {
		'Net::DNS'          => 0,
		'LWP'               => 0,
		'URI'               => 0,
		'Sub::Name'         => 0,
		'Scalar::Util'      => 0,
		# 'IO::Socket::SSL' => 0,     # for HTTPS
		# 'SNMP'            => 0,     # for IO::Lambda::SNMP
		# 'AnyEvent'        => 0,     # for alternative event loop
		# 'Authen::NTLM'    => 1.05,  # for HTTP authentication
	},
	clean         => { FILES => 't/online.enabled' },
);
