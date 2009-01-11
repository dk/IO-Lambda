use strict;
use Socket;
use IO::Handle;
use Time::HiRes qw(time);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(EWOULDBLOCK EINPROGRESS EINTR EAGAIN);

$SIG{PIPE} = undef;
$SIG{IO} = undef if exists $SIG{IO};

my $socket = IO::Handle-> new;
socket( $socket, PF_INET, SOCK_STREAM, getprotobyname('tcp'))
    or die "socket() error:$!";
my $addr = inet_aton('www.google.com')
    or die "cannot resolve www.google.com";
my $name = sockaddr_in( 80, $addr);

# query existing socket flags
if ( $^O ne 'MSWin32') {
    my $flags = fcntl( $socket, F_GETFL, 0);
    die "fcntl() error:$!" unless defined $flags;
    # add non-blocking flag
    fcntl( $socket, F_SETFL, $flags | O_NONBLOCK)
       or die "fcntl() error:$!";
}

my $ok = connect( $socket, $name);
$ok = 1 if not($ok) && ($! == EWOULDBLOCK || $! == EINPROGRESS);
die "Connect error: $!" unless $ok;

my $write = '';
# TCP connect will be marked as writable when 
# either is succeeds, or error occurs
vec( $write, fileno( $socket ), 1) = 1;

# wait for 10 seconds
my $time    = time;
my $timeout = 10;

RESTART:
my $n_files = select( undef, $write, undef, $timeout);
if ( $n_files < 0) {
     die "select() error:$!" unless $! == EINTR or $! == EAGAIN;
     # use Time::HiRes qw(time) is recommended
     $timeout = time - $time;
     goto RESTART;
}

my $error = unpack('i', getsockopt( $socket, SOL_SOCKET, SO_ERROR));
if ($error) {
      # This trick uses duality of error scalar $! and its
      # counterpart $^E on Windows. These scalars report (and assign)
      # error numbers as integers, but in string context return
      # system-specific error description.
      if ( $^O eq 'MSWin32') {
          $^E = $error;
          die "connect() error: $^E";
      } else {
          $! = $error;
          die "connect() error: $!";
      }
}

print "connected ok\n";
