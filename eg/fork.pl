# $Id: fork.pl,v 1.1 2008/11/04 21:19:48 dk Exp $
use strict;
use IO::Lambda qw(:lambda);
use IO::Lambda::Fork qw(forked);

lambda {
    context 0.1, forked {
          select(undef,undef,undef,0.8);
          return "hello!";
    };
    any_tail {
        if ( @_) {
            print "done: ", $_[0]-> peek, "\n";
        } else {
            print "not yet\n";
            again;
        }
    };
}-> wait;

