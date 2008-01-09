#! /usr/bin/perl
# $Id: 99_pod_coverage.t,v 1.8 2008/01/09 11:47:18 dk Exp $

use strict;
use warnings;

use Test::More;

eval 'use Test::Pod::Coverage';
plan skip_all => 'Test::Pod::Coverage required for testing POD coverage'
     if $@;


plan tests => 5;
pod_coverage_ok( 'IO::Lambda' => { trustme => [qr/^(add_\w+|\w+_handler|drive|start|cancel_all_events|remove_loop)$/x] });
pod_coverage_ok( 'IO::Lambda::Loop::Select' => { trustme => [qr/^(rebuild_vectors)$/x] });
pod_coverage_ok( 'IO::Lambda::HTTP' => { trustme => [qr/^(parse|http_protocol|got_\w+|
	handle_\w+|connect|get_protocol|init_request)$/x] });
pod_coverage_ok( 'IO::Lambda::HTTPS' => { trustme => [qr/^(https_protocol|handle_read)$/x] });
pod_coverage_ok( 'IO::Lambda::SNMP' => {trustme => [qr/^(snmp\w+|wrapper)$/x]});
