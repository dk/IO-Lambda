#! /usr/bin/perl
# $Id: 99_pod_coverage.t,v 1.11 2008/05/07 17:48:00 dk Exp $

use strict;
use warnings;

use Test::More;

eval 'use Test::Pod::Coverage';
plan skip_all => 'Test::Pod::Coverage required for testing POD coverage'
     if $@;


plan tests => 5;
pod_coverage_ok( 'IO::Lambda' => { trustme => [qr/^(add_\w+|\w+_handler|drive|start|cancel_\w+|remove_loop)$/x] });
pod_coverage_ok( 'IO::Lambda::Loop::Select' => { trustme => [qr/^(rebuild_vectors)$/x] });
pod_coverage_ok( 'IO::Lambda::HTTP' => { trustme => [qr/^(parse|http_\w+|
	handle_\w+|connect|prepare_transport)$/x] });
pod_coverage_ok( 'IO::Lambda::DNS');
pod_coverage_ok( 'IO::Lambda::Signal' => { trustme => [qr/_(handler|signal|lambda)$/x] });
