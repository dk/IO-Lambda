# $Id: Thread.pm,v 1.8 2008/11/04 19:04:08 dk Exp $
package IO::Lambda::Thread;
use base qw(IO::Lambda);

our $DEBUG = $IO::Lambda::DEBUG{thread};
	
use strict;
use warnings;
use threads;
use Exporter;
use Socket;
use IO::Handle;
use IO::Lambda qw(:all :dev);

our @EXPORT_OK = qw(threaded);

sub _d { "threaded(" . _o($_[0]) . ")" }

sub new
{
	my ( $class, $cb, @param) = @_;
	my $self = $class-> SUPER::new(\&init);
	$self-> autorestart(0);
	$self-> {thread_code}  = $cb;
	$self-> {thread_param} = \@param;
	return $self;
}

sub thread_kill { threads-> exit(0) };

sub thread_init
{
	my ( $self, $r, $cb, @param) = @_;
	$SIG{KILL} = \&thread_kill;
	$SIG{PIPE} = 'IGNORE';
	warn _d($self), ": thread(", threads->tid, ") started\n" if $DEBUG;
	my @ret;
	eval { @ret = $cb->($r, @param) if $cb };
	warn _d($self), ": thread(", threads->tid, ") ended: [@ret]\n" if $DEBUG;
	close($r);
	die $@ if $@;
	return @ret;
}

sub on_read
{
	my $self = shift;
	warn _d($self), ": am closing on read\n" if $DEBUG;
	$self-> {join_on_read} = undef;
	return $self-> join;
}

sub init
{
	my $self = shift;

	$self-> {thread_self} = threads-> tid;

	my $r = IO::Handle-> new;
	$self-> {handle} = IO::Handle-> new;
	socketpair( $r, $self-> {handle}, AF_UNIX, SOCK_STREAM, PF_UNSPEC);
	$self-> {handle}-> blocking(0);

	($self-> {thread_id}) = threads-> create(
		\&thread_init, 
		"$self", $r, $self-> {thread_code},
		@{ $self-> {thread_param} },
	);
	close($r);
	undef $self-> {thread_code};
	undef $self-> {thread_param};

	warn _d($self), ": new thread(", $self-> {thread_id}->tid, ")\n" if $DEBUG;
	$self-> join_on_read(1);
}

sub join_on_read
{
	my ( $self, $join_on_read) = @_;
	if ( $join_on_read) {
		return if $self-> {join_on_read};
	 	my $error = unpack('i', getsockopt( $self-> {handle}, SOL_SOCKET, SO_ERROR));
		if ( $error) {
			warn _d($self), ": join_on_read aborted, handle is invalid\n" if $DEBUG;
			$self-> join;
			return;
		}
		if ( $self-> is_stopped) {
			warn _d($self), ": join_on_read aborted, lambda already stopped\n" if $DEBUG;
			$self-> join;
			return;
		}
		$self-> {join_on_read} = $self-> watch_io(
			IO_READ, $self-> {handle}, 
			undef, \&on_read
		);
		warn _d($self), ": will join on read\n" if $DEBUG;
	} else {
		return unless $self-> {join_on_read};
		$self-> cancel_event( $self-> {join_on_read} );
		$self-> {join_on_read} = undef;
		warn _d($self), ": won't join on read\n" if $DEBUG;
	}
}

my $__warned = 0;
sub kill
{
	my $self = $_[0];
	return unless
		$self-> {thread_id} and
		$self-> {thread_self} == threads-> tid;

	my $t = $self-> {thread_id};
	warn _d($self), ": kill(", $t->tid, ")\n" if $DEBUG;
	undef $self-> {thread_id};

	if ( $] < 5.010) {
		warn <<WARN unless $__warned++;
Perl versions older than 5.10.0 cannot detach and kill threads gracefully.
IO::Lambda::Thread is designed so that programmer doesn't and shouldn't care
about waiting for long-running threads, which works only on higher perl
version. Consider calling \$threaded_lambda->join() to avoid this
warning, or upgrade to 5.10.0 .
WARN
		return;
	}

	if ( $t-> is_running) {
		$t-> detach;
		$t-> kill('KILL');
	} else {
		warn _d($self), " joining ", $t-> tid, "...\n" if $DEBUG;
		$t-> join if $t-> is_joinable;
		warn _d($self), " done ", $t-> tid, "\n" if $DEBUG;
	}
}

sub join
{
	my $self = shift;
	my $t;
	return unless $t = $self-> {thread_id};
	undef $self-> {thread_id};
	warn _d($self), " joining thread ", $t-> tid, "...\n" if $DEBUG;
	my @r = $t-> join;
	@r = $t-> error if $] >= 5.010 and $t-> error;
	warn _d($self), " thread ", $t-> tid, " joined ok\n" if $DEBUG;
	return @r;
}

sub thread { $_[0]-> {thread_id} }
sub socket { $_[0]-> {handle} }

sub DESTROY
{
	my $self = $_[0];
	$self-> SUPER::DESTROY
		if defined($self-> {thread_self}) and
		$self-> {thread_self} == threads-> tid;
	close($self-> {handle}) if $self-> {handle};
	$self-> kill;
}

sub threaded(&) { __PACKAGE__-> new(_subname(threaded => $_[0]) ) }

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::Thread - wait for blocking code using threads

=head1 DESCRIPTION

The module implements a lambda wrapper that allows to asynchronously 
wait for blocking code. The wrapping is done so that the code is
executed in another thread's context. C<IO::Lambda::Thread> inherits
from C<IO::Lambda>, and thus provides all function of the latter to
the caller. In particular, it is possible to wait for these objects
using C<tail>, C<wait>, C<any_tail> etc standard waiter function.

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

=item new($class, $code)

Creates a new C<IO::Lambda::Thread> object in the passive state.  When the lambda
will be activated, a new thread will start, and C<$code> code will be executed
in the context of this new thread. Upon successfull finish, result of C<$code>
in list context will be stored on the lambda.

=item kill

Sends I<KILL> signal to the thread, executing the blocking code, and detaches
it.  Due to perl implementations of safe signals, the thread will not be killed
immediately, but on the next possibility. Given that the module is specifically
made for waiting on long, blocking calls, it is possible that such possibility
can appear in rather long time.

=item threaded($code)

Same as C<new> but without a class.

=item thread

Returns internal thread object

=item join

Joins the internal thread. Can be needed for perl versions before 5.10.0,
that can't kill a thread reliably. 

=back

=head1 BUGS

Threaded lambdas, just as normal lambdas, should be automatically destroyed
when their reference count goes down to zero. When they do so, they try to kill
whatever attached threads they have, using C<threads::detach> and
C<threads::kill>. However, this doesn't always work, may result in error
messages such as 

  Perl exited with active threads:
        1 running and unjoined
        0 finished and unjoined
        0 running and detached

which means that some threads are still running. To avoid this problem,
kill leftover threaded lambdas with C<kill>. 

Note, that a reason that the reference counting does not goes to zero even when
a lambda goes out of scopy, may be because of the fact that lambda context,
which switches dynamically for each lambda callback, still contains the lambda.
C<< $lambda-> clear >> empties the context, and thus any leftover references
from there.

=head1 SEE ALSO

L<IO::Lambda>, L<threads>.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
