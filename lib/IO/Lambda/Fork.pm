# $Id: Fork.pm,v 1.2 2008/11/05 12:39:21 dk Exp $

package IO::Lambda::Fork;

use base qw(IO::Lambda);

our $DEBUG = $IO::Lambda::DEBUG{fork};
	
use strict;
use warnings;
use Exporter;
use Socket;
use POSIX;
use IO::Handle;
use IO::Lambda qw(:all :dev);
use IO::Lambda::Signal;

our @EXPORT_OK = qw(forked);

sub _d { "forked(" . _o($_[0]) . ")" }

sub new
{
	my ( $class, $cb, @param) = @_;
	my $self = $class-> SUPER::new(\&init);
	$self-> autorestart(0);
	$self-> {forked_code}  = $cb;
	$self-> {forked_param} = \@param;
	$self-> {buf} = undef;
	return $self;
}

sub forked_run
{
	my ($self,$r) = @_;
	$SIG{PIPE} = 'IGNORE';
	warn _d($self), ": forked process $$ started\n" if $DEBUG;
	my $ret;
	eval {
		$ret = $self-> {forked_code}-> (
			$r,
			@{$self-> {forked_param}}
		) if $self-> {forked_code}
	};
	warn _d($self), ": forked process $$ ended: [$ret/$@]\n" if $DEBUG;
	print $r $@ ? $@ : $ret if $@ or defined $ret;
	close $r;
	POSIX::exit( $@ ? 1 : 0);
}

sub on_sigchld
{
	my ( $self, $exitcode) = @_;
	warn _d($self), ": exitcode $exitcode\n" if $DEBUG;
	$self-> {exitcode} = $exitcode;
	return ($exitcode, $self-> {buf}) unless $self-> {listen};
	$self-> watch_lambda( $self-> {listen}, sub {
		return ($self-> {exitcode}, $self-> {buf});
	});
}

sub init
{
	my $self = shift;

	my $r = IO::Handle-> new;
	$self-> {handle} = IO::Handle-> new;
	socketpair( $r, $self-> {handle}, AF_UNIX, SOCK_STREAM, PF_UNSPEC);
	$self-> {handle}-> blocking(0);

	$self-> {pid} = fork;
	return ( undef, $! ) unless defined $self-> {pid};
	$self-> forked_run($r) unless $self-> {pid};

	close($r);
	undef $self-> {forked_code};
	undef $self-> {forked_param};

	$self-> watch_lambda(
		IO::Lambda::Signal::new_pid( $self-> {pid}),
		\&on_sigchld,
	);

	warn _d($self), ": new process($self->{pid})\n" if $DEBUG;
	$self-> listen(1);
}

sub listen
{
	my ( $self, $listen) = @_;
	if ( $listen) {
		return if $self-> {listen};
	 	my $error = unpack('i', getsockopt( $self-> {handle}, SOL_SOCKET, SO_ERROR));
		if ( $error) {
			warn _d($self), ": listen aborted, handle is invalid\n" if $DEBUG;
			return;
		}
		if ( $self-> is_stopped) {
			warn _d($self), ": listen aborted, lambda already stopped\n" if $DEBUG;
			$self-> join;
			return;
		}
		$self-> {listen} = lambda {
			# wait for EOF
			context readbuf, $self-> {handle}, \ $self-> {buf}, undef;
		tail {
			my ($res, $error) = @_;
			warn _d($self), 
				( $error
					? ": error $error"
					: ": read ", length($res), " bytes"
				), "\n" if $DEBUG;
		}};
		$self-> {listen}-> start;

		warn _d($self), ": listening\n" if $DEBUG;
	} else {
		return unless $self-> {listen};
		$self-> {listen}-> terminate;
		$self-> {listen} = undef;
		warn _d($self), ": not listening\n" if $DEBUG;
	}
}

sub kill
{
	my ( $self, $sig) = @_;

	return unless $self-> {pid};

	$sig = 'TERM' unless defined $sig;
	return CORE::kill( $self-> {pid}, $sig);
}

sub join
{
	my $self = shift;
	return unless $self-> {pid};
	warn _d($self), ": waiting pid $self->{pid}\n" if $DEBUG;
	waitpid($self->{pid},0);
	warn _d($self), ": ok\n" if $DEBUG;
}

sub pid    { $_[0]-> {pid} }
sub socket { $_[0]-> {handle} }

sub DESTROY
{
	my $self = $_[0];
	$self-> SUPER::DESTROY if defined($self-> {pid});
	undef $self-> {pid};
	close($self-> {handle}) if $self-> {handle};
	$self-> kill;
}

sub forked(&) { __PACKAGE__-> new(_subname(forked => $_[0]) ) }

1;
