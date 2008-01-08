#! /usr/bin/perl
# $Id: 99_pod_coverage.t,v 1.6 2008/01/08 14:02:39 dk Exp $

use strict;
use warnings;

use Test::More tests => 5;

eval 'use Test::Pod::Coverage';
plan skip_all => 'Test::Pod::Coverage required for testing POD coverage'
     if $@;
pod_coverage_ok( 'IO::Lambda' => { trustme => [qr/^(add_\w+|\w+_handler|drive|start|cancel_all_events|remove_loop)$/x] });
pod_coverage_ok( 'IO::Lambda::Loop::Select' => { trustme => [qr/^(rebuild_vectors)$/x] });
pod_coverage_ok( 'IO::Lambda::HTTP' => { trustme => [qr/^(parse|redirect_request|
	single_request|uri_to_socket|got_content|init_request)$/x] });
pod_coverage_ok( 'IO::Lambda::HTTPS' => { trustme => [qr/^(single_request|handle_read)$/x] });
pod_coverage_ok( 'IO::Lambda::SNMP' => {trustme => [qr/^(snmp\w+|wrapper)$/x]});
