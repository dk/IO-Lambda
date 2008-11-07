# $Id: Signal.pm,v 1.13 2008/11/07 09:36:38 dk Exp $
package IO::Lambda::Signal;
use vars qw(@ISA %SIGDATA);
@ISA = qw(Exporter);
@EXPORT_OK = qw(signal pid spawn);
%EXPORT_TAGS = ( all => \@EXPORT_OK);

our $DEBUG = $IO::Lambda::DEBUG{signal};

use strict;
use Carp;
use IO::Handle;
use POSIX ":sys_wait_h";
use IO::Lambda qw(:all);

my $MASTER = bless {}, __PACKAGE__;

# register yield handler
IO::Lambda::add_loop($MASTER);
END { IO::Lambda::remove_loop($MASTER) };

sub remove {}
sub empty { 0 == keys %SIGDATA }

sub yield
{
	my @v = values %SIGDATA;
	for my $v ( @v) {
		# use mutex in case signal happens right here during handling
		$v-> {mutex} = 0;
	AGAIN:  
		next unless $v-> {signal};

		my @r = @{$v-> {lambdas}};
		for my $r ( @r) {
			my ( $lambda, $callback, @param) = @$r;
			$callback-> ( $lambda, @param);
		}

		my $sigs = $v-> {mutex};
		if ( $sigs) {
			$v-> {signal} = $sigs;
			$v-> {mutex}  -= $sigs;
			goto AGAIN;
		}
	}
}

sub signal_handler
{
	my $id = shift;
	warn "SIG{$id}\n" if $DEBUG;
	return unless exists $SIGDATA{$id};
	$SIGDATA{$id}-> {signal}++;
	$SIGDATA{$id}-> {mutex}++;
}

sub watch_signal
{
	my ($id, $lambda, $callback, @param) = @_;

	my $entry = [ $lambda, $callback, @param ];
	unless ( exists $SIGDATA{$id}) {
		$SIGDATA{$id} = {
			mutex   => 0,
			signal  => 0,
			save    => $SIG{$id},
			lambdas => [$entry],
		};
		$SIG{$id} = sub { signal_handler($id) };
	} else {
		push @{ $SIGDATA{$id}-> {lambdas} }, $entry;
	}
}

sub unwatch_signal
{
	my ( $id, $lambda) = @_;

	return unless exists $SIGDATA{$id};

	@{ $SIGDATA{$id}-> {lambdas} } = 
		grep { $$_[0] != $lambda } 
		@{ $SIGDATA{$id}-> {lambdas} };
	
	return if @{ $SIGDATA{$id}-> {lambdas} };

	if (defined($SIGDATA{$id}-> {save})) {
		$SIG{$id} = $SIGDATA{$id}-> {save};
	} else {
		delete $SIG{$id};
	}
	delete $SIGDATA{$id};
}

# create a lambda that either returns undef on timeout,
# or some custom value based on passed callback
sub signal_or_timeout_lambda
{
	my ( $id, $deadline, $condition) = @_;

	my $t;
	my $q = IO::Lambda-> new;

	# wait for signal
	my $c = $q-> bind;
	watch_signal( $id, $q, sub {
		my @ret = $condition-> ();
		return unless @ret;

		unwatch_signal( $id, $q);
		$q-> cancel_event($t) if $t;
		$q-> resolve($c);
		$q-> terminate(@ret); # result
		undef $c;
		undef $q;
	});

	# or wait for timeout
	$t = $q-> watch_timer( $deadline, sub {
		unwatch_signal( $id, $q);
		$q-> resolve($c);
		undef $c;
		undef $q;
		return undef; #result
	}) if $deadline;

	return $q;
}

sub new_signal
{
	my ( $id, $deadline) = @_;
	signal_or_timeout_lambda( $id, $deadline, 
		sub { 1 });
}

sub new_pid
{
	my ( $pid, $deadline) = @_;

	croak 'bad pid' unless $pid =~ /^\-?\d+$/;
	
	# avoid race conditions
	my ( $savesig, $signalled);
	unless ( defined $SIGDATA{CHLD}) {
		$savesig   = $SIG{CHLD};
		$signalled = 0;
		$SIG{CHLD} = sub { $signalled++ };
	}

	# finished already
	if ( waitpid( $pid, WNOHANG) > 0) {
		if ( defined( $savesig)) {
			$SIG{CHLD} = $savesig;
		} else {
			delete $SIG{CHLD};
		}
		return IO::Lambda-> new-> call($?) 
	}

	# wait
	my $p = signal_or_timeout_lambda( 'CHLD', $deadline, 
		sub { (waitpid($pid, WNOHANG) == 0) ? () : $? });

	# don't let unwatch_signal() to restore it back to us
	$SIGDATA{CHLD}-> {save} = $savesig if defined $signalled;

	# possibly have a race? gracefully remove the lambda
	if ( $signalled) {

		# Got a signal, but that wasn't our pid. And neither it was
		# pid that we're watching.
		return $p if waitpid( $pid, WNOHANG) == 0;

		# Our pid is finished. Unwatch the signal.
		unwatch_signal( 'CHLD', $p);
		# Lambda will also never get executed - cancel it
		$p-> terminate;
	
		return IO::Lambda-> new-> call($?); 
	}

	return $p;
}

sub new_process
{ 
lambda {
	my $cmd = @_;
	my $h   = IO::Handle-> new;
	my $pid = open( $h, '-|', @_);

	return undef, undef, $! unless $pid;

	this-> {pid} = $pid;
	$h-> blocking(0);

	my $buf;
	context readbuf, $h, \$buf, undef; # wait for EOF
tail {
	my ($res, $error) = @_;
	if ( defined $error) {
		close $h;
		return ($buf, $?, $error);
	}
	return ($buf, $?, $!) unless close $h;
	# finished already
	return ($buf, $?, $!) if waitpid($pid, WNOHANG) >= 0;

	# wait for it
	context $pid;
pid {
	return ($buf, shift);
}}}}

# predicates
sub signal (&) { new_signal (context)-> predicate(shift, \&signal, 'signal') }
sub pid    (&) { new_pid    (context)-> predicate(shift, \&pid,    'pid') }
sub spawn  (&) { new_process-> call(context)-> predicate(shift, \&spawn,  'spawn') }


1;

__DATA__

=pod

=head1 NAME

IO::Lambda::Signal - wait for pids and signals

=head1 DESCRIPTION

The module provides access to signal-based callbacks, generic signal listener
C<signal>, process ID listener C<pid>, and asynchronous version of I<system>
call, C<spawn>.

=head1 SYNOPSIS

   use strict;
   use IO::Lambda qw(:all);
   use IO::Lambda::Signal qw(pid spawn);

   # pid
   my $pid = fork;
   exec "/bin/ls" unless $pid;
   lambda {
       context $pid, 5;
       pid {
          my $ret = shift;
	  print defined($ret) ? ("exitcode(", $ret>>8, ")\n") : "timeout\n";
       }
   }-> wait;

   # spawn
   this lambda {
      context "perl -v";
      spawn {
      	  my ( $buf, $exitcode, $error) = @_;
   	  print "buf=[$buf], exitcode=$exitcode, error=$error\n";
      }
   }-> wait;

=head2 USAGE

=over

=item pid ($PID, $TIMEOUT) -> $?|undef

Accepts PID and optional deadline/timeout, returns either process exit status,
or undef on timeout.  The corresponding lambda is C<new_pid> :

   new_pid ($PID, $TIMEOUT) :: () -> $?|undef

=item signal ($SIG, $TIMEOUT) -> boolean

Accepts signal name and optional deadline/timeout, returns 1 if signal was caught,
or C<undef> on timeout.  The corresponding lambda is C<new_signal> :

   new_signal ($SIG, $TIMEOUT) :: () -> boolean

=item spawn (@LIST) -> ( output, $?, $!)

Calls pipe open on C<@LIST>, read all data printed by the child process,
and waits for the process to finish. Returns three scalars - collected output,
process exitcode C<$?>, and an error string (usually C<$!>). The corresponding
lambda is C<new_process> :

   new_process (@LIST) :: () -> ( output, $?, $!)

Lambda created by C<new_process> has field C<'pid'> set to the process pid.

=back

=head1 LIMITATIONS

C<spawn> doesn't work on Win32, because pipes don't work with win32's select.
They do (see L<Win32::Process>) work with win32-specific
C<WaitforMultipleObjects>, which in turn IO::Lambda doesn't work with.

L<IPC::Run> apparently manages to work on win32 B<and> be compatible with
C<select>. I don't think that dragging C<IPC::Run> as a dependency here
worth it, but if you need it, send me a working example so I can at least include
it here.

=head1 SEE ALSO

L<IO::Lambda>, L<perlipc>, L<IPC::Open2>, L<IPC::Run>, L<Win32::Process>.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
