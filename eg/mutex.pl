# $Id: mutex.pl,v 1.1 2009/01/16 17:06:16 dk Exp $

# Example of use of mutexes

use strict;
use warnings;
use IO::Lambda qw(:lambda);
use IO::Lambda::Mutex qw(mutex);

my $mutex = IO::Lambda::Mutex-> new;

# wait for mutex that shall be available immediately
my $waiter = $mutex-> waiter;
my $error = $waiter-> wait;
die "error:$error" if $error;

# create and start a lambda that sleep 2 seconds and then releases the mutex
my $sleeper = lambda {
	context 2;
	timeout { $mutex-> release }
};
$sleeper-> start;

# Create a new lambda that shall only wait for 0.5 seconds.
# It will surely fail.
lambda {
	context $mutex-> waiter(0.5);
	tail {
		my $error = shift;
		print $error ? "error:$error\n" : "ok\n";
		# $error is expected to be 'timeout'
	}
}-> wait;

# Again, wait for the same mutex but using different syntax.
# This time should be ok.
lambda {
    context $mutex, 3;
    mutex {
        my $error = shift;
        print $error ? "error:$error\n" : "ok\n";
        # expected to be 'ok'
    }
}-> wait;
