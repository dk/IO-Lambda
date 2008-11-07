# $Id: Thread.pm,v 1.14 2008/11/07 17:51:08 dk Exp $
package IO::Lambda::Thread;
use base qw(IO::Lambda);
use strict;
use warnings;
use Exporter;
use Socket;
use IO::Handle;
use IO::Lambda qw(:all :dev);

our $DISABLED;
eval { require threads; };
$DISABLED = $@ if $@;

our $DEBUG = $IO::Lambda::DEBUG{thread};

our @EXPORT_OK = qw(threaded new_thread);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

sub _d { "threaded(" . _o($_[0]) . ")" }

sub thread_init
{
	my ( $r, $cb, $pass_handle, @param) = @_;

	$SIG{KILL} = sub { threads-> exit(0) };
	$SIG{PIPE} = 'IGNORE';
	warn "thread(", threads->tid, ") started\n" if $DEBUG;

	my @ret;
	eval { @ret = $cb-> (( $pass_handle ? $r : ()), @param) if $cb };

	warn "thread(", threads->tid, ") ended: [@ret]\n" if $DEBUG;
	close($r);
	undef $r;
	die $@ if $@;

	return @ret;
}

sub new_thread
{
	return undef, $DISABLED if $DISABLED;

	my ( @args, $cb, $pass_handle, @param);
	@args = shift if $_[0] and ref($_[0]) and ref($_[0]) eq 'HASH';
	( $cb, $pass_handle, @param) = @_;
	
	my $r = IO::Handle-> new;
	my $w = IO::Handle-> new;
	socketpair( $r, $w, AF_UNIX, SOCK_STREAM, PF_UNSPEC);
	$w-> blocking(0);

	my ($t) = threads-> create(
		@args,
		\&thread_init, 
		$r, $cb, $pass_handle, @param
	);

	close($r);

	warn "new thread(", $t->tid, ")\n" if $DEBUG;
	return ($t, $w);
}

# XXX $thread-> detach/kill when cancelled
sub threaded(&)
{
	my $cb = shift;

	lambda { 
		my ( $t, $r) = new_thread( $cb, 1 );
		return $r unless $t;

		context $r;
	read {
		close($r);
		undef $r;
		this-> clear;
		return $t-> join;
	}}
}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::Thread - wait for blocking code using threads

=head1 DESCRIPTION

The module implements a lambda wrapper that allows to asynchronously wait for
blocking code. The wrapping is done so that the code is executed in another
thread's context. C<IO::Lambda::Thread> provides bidirectional communication
between threads, which is based on a shared socket between parent and child
threads. This socket can be used by the caller for its own needs, if necessary.

=head1 SYNOPSIS

    use IO::Lambda qw(:lambda);
    use IO::Lambda::Thread qw(threaded);

    lambda {
        context 0.1, threaded {
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

=head1 API

=over

=item new_thread ( $options = (), $pass_socket, $code, @param) -> ($thread, $socket)

A special replacement for C<< thread-> create >>, that not only creates a
thread, but also creates a socket between the parent and child threads. That
socket is important for getting an asynchronous notification when the child
thread has finished, because there is no portable way to get that signal
otherwise. That means that this socket must be closed and the thread must be
C<join>'ed to avoid problems. For example:
    
    my ( $thread, $reader) = new_thread( $sub {
        my $writer = shift;
        print $writer, "Hello world!\n";
    }, 1 );
    print while <$reader>;
    close($reader);
    $thread-> join;

Note that C<join> is a blocking call, so one might want to be sure that the
thread is indeed finished before calling it. By default, the child thread will
close its side of the socket, thus making the parent side readable. However,
the child code can also hijack the socket for its own needs, so if that
functionality is needed, one must create an extra layer of communication that
will ensure that the child code is properly exited, so that the parent can
reliably call C<join> without blocking.

C<$code> is executed in another thread's context, and is passed the communication
socket ( if C<$pass_socket> is set to 1 ). C<$code> is also passed C<@param>.
Data returned from the code can be retrieved from C<join>.

=item threaded($code) :: () -> ( @results )

Creates a lambda, that will execute C<$code> in a newly created thread.
The lambda will finish when the C<$code> and the thread are finished,
and will return results returned by C<$code>.

=back

=head1 BUGS

If lambdas created by C<threaded> are permaturely cancelled, then
the associated threas will not be properly waited for. Errors
like one below may ensue.

  Perl exited with active threads:
        1 running and unjoined
        0 finished and unjoined
        0 running and detached

=head1 SEE ALSO

L<IO::Lambda>, L<threads>.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
