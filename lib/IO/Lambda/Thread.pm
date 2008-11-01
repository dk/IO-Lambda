# $Id: Thread.pm,v 1.2 2008/11/01 19:50:20 dk Exp $
package IO::Lambda::Thread;
use base qw(IO::Lambda);

our $DEBUG = $ENV{IO_THREAD_DEBUG};
	
use strict;
use warnings;
use threads;
use Exporter;
use Socket;
use IO::Handle;
use IO::Lambda qw(:all :dev);

our @EXPORT_OK = qw(threaded);

sub _t   { "threaded(" . _obj($_[0]) . ")" }
sub _obj { $_[0] =~ /0x([\w]+)/; $1 }

sub new
{
	my ( $class, $cb) = @_;
			
	$class-> SUPER::new( sub {
		my $self = shift;
		$self-> {thread_self} = threads-> tid;

		my $r = IO::Handle-> new;
		my $w = IO::Handle-> new;
		socketpair( $r, $w, AF_UNIX, SOCK_STREAM, PF_UNSPEC);

		my $self_id;
		$self_id = "$self" if $DEBUG;

		my ($t) = threads-> create( sub {
			$SIG{KILL} = sub { threads-> exit(0) };
			warn _t($self_id), ": thr started\n" if $DEBUG;
			my @ret = $cb ? $cb->() : ();
			warn _t($self_id), ": thr ended: [@ret]\n" if $DEBUG;
			syswrite( $r, "0");
			return @ret;
		});
		
		warn _t($self), ": new thread(", _obj($t), ")\n" if $DEBUG;
	
		my $rec = $self-> watch_io( IO_READ, $w, undef, sub {
			my $self = $_[0];
			$self-> {thread_id} = undef;
			warn _t($self), " joining ", _obj($t), "...\n" if $DEBUG;
			my @ret = $t-> join;
			close($r);
			close($w);
			warn _t($self), " done: ", _obj($t), " > [@ret]\n" if $DEBUG;
			return @ret;
		});

		$self-> {thread_id} = $t;
	});
}

my $__warned = 0;
sub kill
{
	my $self = $_[0];
	return unless
		$self-> {thread_id} and
		$self-> {thread_self} == threads-> tid;

	my $t = $self-> {thread_id};
	warn _t($self), ": kill(", _obj($t), ")\n" if $DEBUG;
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
		$t-> join if $t-> is_joinable;
	}
}

sub join
{
	my $self = shift;
	my $t;
	return unless $t = $self-> {thread_id};
	undef $self-> {thread_id};
	$t-> join;
}

sub thread { $_[0]-> {thread_id} }

sub DESTROY
{
	my $self = $_[0];
	$self-> SUPER::DESTROY
		if defined($self-> {thread_self}) and
		$self-> {thread_self} == threads-> tid;
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
