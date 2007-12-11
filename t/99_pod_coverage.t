#! /usr/bin/perl
# $Id: 99_pod_coverage.t,v 1.1 2007/12/11 14:48:38 dk Exp $

use strict;
use warnings;

use Test::More;
eval 'use Test::Pod::Coverage';
plan skip_all => 'Test::Pod::Coverage required for testing POD coverage'
    if $@;
all_pod_coverage_ok();
