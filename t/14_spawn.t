#! /usr/bin/perl
# $Id: 14_spawn.t,v 1.1 2008/08/15 14:51:00 dk Exp $

use strict;
use warnings;
use Test::More;
use IO::Lambda qw(:lambda);
use IO::Lambda::Signal qw(:all);

plan skip_all => "Doesn't work on Win32" if $^O =~ /win32/i;
plan tests    => 2;

this lambda {
	context "$^X -v";
	spawn {
		my ( $buf, $exitcode, $error) = @_;
		return $buf;
	}
};

ok( this-> wait =~ /This is perl/s, 'good spawn');

this lambda {
	context "./nothere 2>&1";
	spawn {
		my ( $buf, $exitcode, $error) = @_;
		return not defined($buf);
	}
};

ok( this-> wait, 'bad spawn');
