#! /usr/bin/perl
# $Id: 99_pod_coverage.t,v 1.9 2008/01/25 13:46:04 dk Exp $

use strict;
use warnings;

use Test::More;

eval 'use Test::Pod::Coverage';
plan skip_all => 'Test::Pod::Coverage required for testing POD coverage'
     if $@;


plan tests => 5;
pod_coverage_ok( 'IO::Lambda' => { trustme => [qr/^(add_\w+|\w+_handler|drive|start|cancel_all_events|remove_loop)$/x] });
pod_coverage_ok( 'IO::Lambda::Loop::Select' => { trustme => [qr/^(rebuild_vectors)$/x] });
pod_coverage_ok( 'IO::Lambda::HTTP' => { trustme => [qr/^(parse|http_\w+|
	handle_\w+|connect|prepare_transport)$/x] });
pod_coverage_ok( 'IO::Lambda::HTTPS' => { trustme => [qr/^(https_\w+)$/x] });
pod_coverage_ok( 'IO::Lambda::SNMP' => {trustme => [qr/^(snmp\w+|wrapper)$/x]});
