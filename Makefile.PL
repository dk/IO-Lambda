# $Id: Makefile.PL,v 1.1 2007/12/11 14:48:38 dk Exp $
use ExtUtils::MakeMaker;
WriteMakefile(
	NAME          => 'IO::Lambda',
	AUTHOR        => 'Dmitry Karasik <dmitry@karasik.eu.org>',
	ABSTRACT_FROM => 'lib/IO/Lambda.pm',
	VERSION_FROM  => 'lib/IO/Lambda.pm',
#
## Yes, I know the library has IO::Lambda::HTTP and IO::Lambda::HTTPS, and
## I can add LWP as a dependency, but what happens when I add IO::Lambda::SNMP
## and IO::Lambda::Loop::AnyEvent or whatever? That is the question.
#	PREREQ_PM     => {
#		
#	},
);
