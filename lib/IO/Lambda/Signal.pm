# $Id: Signal.pm,v 1.3 2008/05/20 09:40:12 dk Exp $
package IO::Lambda::Signal;
use vars qw(@ISA %SIGDATA);
@ISA = qw(Exporter);
@EXPORT_OK = qw(signal signal_lambda pid pid_lambda);
%EXPORT_TAGS = ( all => \@EXPORT_OK);

use strict;
use POSIX ":sys_wait_h";
use IO::Lambda qw(:all);

sub watch_signal
{
	my ($id, $lambda, $callback, @param) = @_;

	my $entry = [ $lambda, $callback, @param ];
	unless ( exists $SIGDATA{$id}) {
		$SIGDATA{$id} = {
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

sub signal_handler
{
	my $id = shift;
	warn "SIG{$id}\n" if $IO::Lambda::DEBUG;
	return unless exists $SIGDATA{$id};
	for my $r ( @{$SIGDATA{$id}-> {lambdas}}) {
		my ( $lambda, $callback, @param) = @$r;
		$callback-> ( $lambda, @param);
	}
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

sub signal_lambda
{
	my ( $id, $deadline) = @_;
	signal_or_timeout_lambda( $id, $deadline, 
		sub { 1 });
}

sub pid_lambda
{
	my ( $pid, $deadline) = @_;

	# finished already
	return IO::Lambda-> new-> call($?)
		if waitpid($pid, WNOHANG) >= 0;

	# wait
	signal_or_timeout_lambda( 'CHLD', $deadline, 
		sub { (waitpid($pid, WNOHANG) < 0) ? () : $?  });
}

# predicates
sub signal(&) { this-> add_tail( shift, \&signal, signal_lambda(context), context)}
sub pid   (&) { this-> add_tail( shift, \&pid,    pid_lambda(context),    context)}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::Signal - Wait for pid/signal or timeout

=head1 DESCRIPTION

The module provides access to signal-based callbacks, generic signal listener
C<signal> and process ID listener C<pid>.  Each function is exported in two
flavors: predicate-style C<pid> and lambda-style C<pid_lambda>.

=head1 SYNOPSIS

   use strict;
   use IO::Lambda qw(:all);
   use IO::Lambda::Signal qw(pid);

   my $pid = fork;
   exec "/bin/ls" unless $pid;
   lambda {
       context $pid, 5;
       pid {
          my $ret = shift;
	  print defined($ret) ? ("exitcode(", $ret>>8, ")\n") : "timeout\n";
       }
   }-> wait;

=head2 USAGE

=over

=item pid ($PID, $TIMEOUT) -> $?|undef

Accepts PID and optional deadline/timeout, returns either process exit status,
or undef on timeout.  The corresponding lambda is C<pid_lambda> :

   pid_lambda ($PID, $TIMEOUT) :: () -> $?|undef

=item signal ($SIG, $TIMEOUT) -> boolean

Accepts signal name and optional deadline/timeout, returns 1 if signal was caught,
or C<undef> on timeout.  The corresponding lambda is C<signal_lambda> :

   signal_lambda ($SIG, $TIMEOUT) :: () -> boolean

=back

=head1 SEE ALSO

L<IO::Lambda>

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
