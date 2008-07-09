# $Id: tcp-poe.pl,v 1.2 2008/07/09 14:01:24 dk Exp $
# An echo client-server benchmark
use strict;
use Time::HiRes qw(time);
use POE qw(Component::Server::TCP Component::Client::TCP Filter::Stream);

use strict;
use warnings;

# if too many, then this error appears:
# Client 1023 got getprotobyname error 24 (Too many open files)
# I don't have time now to investigate, but 500 cycles is ok enough
my $CYCLES = 500; 


# http://poe.perl.org/?POE_Cookbook/TCP_Servers

POE::Component::Server::TCP->new
  ( Port => 11211,

    # for a more complex application, you can use Filter::Reference to
    # pass complex data structures as input/output.

    # ClientFilter  => "POE::Filter::Reference",

    ClientInput => sub {
        my ( $sender, $kernel, $heap, $input ) =
          @_[ SESSION, KERNEL, HEAP, ARG0 ];
        $heap->{client}->put( $input )
    },
  );


sub client
{
   my $id = shift;
   my $cl;
   $cl = POE::Component::Client::TCP->new
      ( RemoteAddress => 'localhost',
        RemotePort => 11211,
        Filter     => "POE::Filter::Stream",

        # The client has connected.  Display some status and prepare to
        # gather information.  Start a timer that will send ENTER if the
        # server does not talk to us for a while.

        Connected => sub {
            $_[HEAP]->{server}->put("can write $id\n");    # sends enter
        },

        # The server has sent us something.  Save the information.  Stop
        # the ENTER timer, and begin (or refresh) an input timer.  The
        # input timer will go off if the server becomes idle.

        ServerInput => sub {
            my ( $kernel, $heap, $input, $sess ) = @_[ KERNEL, HEAP, ARG0, SESSION ];
            if ( $id < $CYCLES) {
		delete $heap-> {server};
		client($id+1);
            } else {
            	$kernel-> stop;
            }
        },

      );
}

my $t = time;
client(0);
$poe_kernel->run();
$t = time - $t;
printf "%.3f sec\n", $t;
