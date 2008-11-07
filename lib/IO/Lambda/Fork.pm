# $Id: Fork.pm,v 1.7 2008/11/07 19:54:53 dk Exp $

package IO::Lambda::Fork;

use base qw(IO::Lambda);

our $DEBUG = $IO::Lambda::DEBUG{fork} || 0;
	
use strict;
use warnings;
use Exporter;
use Socket;
use POSIX;
use Storable qw(thaw freeze);
use IO::Handle;
use IO::Lambda qw(:all :dev);
use IO::Lambda::Signal qw(pid);

our @ISA = qw(Exporter);
our @EXPORT_OK = qw(new_process process new_forked forked);
our %EXPORT_TAGS = (all => \@EXPORT_OK);

sub _d { "forked(" . _o($_[0]) . ")" }

# return pid and socket
sub new_process(&)
{
	my $cb = shift;
	
	my $r = IO::Handle-> new;
	my $w = IO::Handle-> new;
	socketpair( $r, $w, AF_UNIX, SOCK_STREAM, PF_UNSPEC);
	$w-> blocking(0);

	my $pid = fork;
	unless ( defined $pid) {
		warn "fork() failed:$!\n" if $DEBUG;
		close($w);
		close($r);
		return ( undef, $! );
	}

	if ( $pid == 0) {
		close($w);
		warn "process($$) started\n" if $DEBUG;
		eval { $cb-> ($r) if $cb; };
		warn "process($$) ended\n" if $DEBUG;
		warn $@ if $@;
		close($r);
		POSIX::exit($@ ? 1 : 0);
	}
		
	warn "forked pid=$pid\n" if $DEBUG;

	close($r);

	return ($pid, $w);
}

# simple fork, return only $? and $!
sub process(&)
{
	my $cb = shift;

	lambda { 
		my $pid = fork;
		return undef, $! unless defined $pid;
		unless ( $pid) {
			warn "process($$) started\n" if $DEBUG;
			eval { $cb->(); };
			warn "process($$) ended\n" if $DEBUG;
			warn $@ if $@;
			POSIX::exit($@ ? 1 : 0);
		}

		warn "forked pid=$pid\n" if $DEBUG;
		context $pid;
		&pid();
	}
	
}

# return output from a subprocess
sub new_forked(&)
{
	my $cb = shift;

	my ( $pid, $r) = new_process {
		my @ret;
		my $socket = shift;
		eval { @ret = $cb-> () if $cb };
		my $msg = $@ ? [ 0, $@ ] : [ 1, @ret ];
		warn "process($$) ended: [@$msg]\n" if $DEBUG > 1;
		print $socket freeze($msg);
	};

	lambda {
		return undef, undef, $r unless defined $pid;
	
		my $buf = '';
		context readbuf, $r, \ $buf, undef;
	tail {
		my ( $ok, $error) = @_;
		my @ret;

		($ok,$error) = (0,$!) unless close($r);

		unless ( $ok) {
			@ret = ( undef, $error);
		} else {
			my $msg;
			eval { $msg = thaw $buf };
			unless ( $msg and ref($msg) and ref($msg) eq 'ARRAY') {
				@ret = ( undef, $@);
			} elsif ( 0 == shift @$msg) {
				@ret = ( undef, @$msg);
			} else {
				@ret = ( 1, @$msg);
			}
		}

		context $pid;
	pid {
		warn "pid($pid): exitcode=$?, [@ret]\n" if $DEBUG > 1;
		return shift, @ret;
	}}}
}

# simpler version of new_forked
sub forked(&)
{
	my $cb = shift;
	lambda {
		context &new_forked($cb);
	tail {
		my ( $pid, $ok, @ret) = @_;
		return @ret;
	}}
}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::Fork - wait for blocking code using coprocesses

=head1 DESCRIPTION

The module implements a lambda wrapper that allows to asynchronously wait for
blocking code. The wrapping is done so that the code is executed in another
process's context. C<IO::Lambda::Fork> provides a twofold interface: First, it
the module can create lambdas that wait for forked child processes. Second, it
also provides an easier way for simple communication between parent and child
processes.

Contrary to the usual interaction between a parent and a forked child process,
this module doesn't hijack the child's stdin and stdout, but uses a shared
socket between them. That socket, in turn, can be retrieved by the caller
and used for its own needs.

=head1 SYNOPSIS

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

=head1 API

=over

=item new_process($code, $pass_socket, @param) -> ( $pid, $socket | undef, $error )

Forks a process, and sets up a read-write socket between the parent and the
child. On success, returns the child's pid and the socket, where the latter is
passed to C<$code>. On failure, returns undef and C<$!>.

This function doesn't create a lambda, and doesn't make any preparation neither
for waiting for the child process, nor for reaping its status. It is therefore
important to wait for the child process, to avoid zombie processes. It can be done either
synchronously:

    my ( $pid, $reader) = new_process {
        my $writer = shift;
        print $writer, "Hello world!\n";
    };
    print while <$reader>;
    close($reader);
    waitpid($pid, 0);

or asynchronously, using lambdas:

    use IO::Lambda::Socket qw(pid new_pid);
    ...
    lambda { context $pid; &pid() }-> wait;
    # or
    new_pid($pid)-> wait;

=item process($code) :: () -> ($? | undef)

Creates a simple lambda that forks a process and executes C<$code> inside it.
The lambda returns the child exit code.

=item new_forked($code) :: () -> ( $?, ( 1, @results | undef, $error))

Creates a lambda that waits for C<$code> in a sub-process to be executed,
and returns its result back to the parent. Returns also the process
exitcode, C<$code> eval success flag, and results (or an error string).

=item forked($code) :: () -> (@results | $error)

A simple wrapper over C<new_forked>, that returns either C<$code> results
or an error string.

=back

=head1 BUGS

Doesn't work on Win32, because relies on C<$SIG{CHLD}> which is not getting
delivered (on 5.10.0 at least). However, since Win32 doesn't have forks anyway,
Perl emulates them with threads. Use L<IO::Lambda::Thread> instead when running
on windows.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
