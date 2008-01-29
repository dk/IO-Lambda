# $Id: Prima.pm,v 1.1 2008/01/29 15:06:51 dk Exp $

package IO::Lambda::Loop::Prima;
use strict;
use warnings;
use IO::Lambda qw(:constants);
use Time::HiRes qw(time);
use Prima qw(Application);

IO::Lambda::Loop::default('Prima');

use vars qw(%filenos @timers $timer $deadline $event @mask $DEBUG);

# $DEBUG = 1;

$mask[IO_READ]      = fe::Read;
$mask[IO_WRITE]     = fe::Write;
$mask[IO_EXCEPTION] = fe::Exception;

sub new { bless {} , shift }

sub reset_mask
{
	my $f = shift;

	my $mask = 0;
	for my $flags ( map { $_-> [WATCH_IO_FLAGS]} @{ $f-> {rec}} ) {
		$mask |= $mask[$_] for grep { $flags & $_ } IO_READ, IO_WRITE, IO_EXCEPTION;
	}
	unless ( $mask == $f-> {mask}) {
		$f-> {object}-> mask($f-> {mask} = $mask);
		warn 
			fileno($f->{object}->file), " set new mask ",
			(( $mask & fe::Read)      ? 'read ' : ''),
			(( $mask & fe::Write)     ? 'write ' : ''),
			(( $mask & fe::Exception) ? 'exception ' : ''),
			"\n"
			if $DEBUG;
	}
}

my ( $in_yield, %masks);
sub on_read      { on_io($_[0], fe::Read)      }
sub on_write     { on_io($_[0], fe::Write)     }
sub on_exception { on_io($_[0], fe::Exception) }
sub on_io
{
	$event++;

	my ( $obj, $flags) = @_;

	my $fileno = fileno($obj-> file);
	warn "event $fileno/$filenos{$fileno}->{mask} $flags\n" if $DEBUG;

	%masks = () unless $in_yield;

	exists ($masks{$fileno}) ? 
		$masks{$fileno} |= $flags :
		$masks{$fileno} = $flags;

	$filenos{$fileno}-> {mask} &= ~$flags;
	$obj-> mask( $filenos{$fileno}-> {mask} );

	return if $in_yield;

	# now wait (not select-wait, just wait for inner loop to finish), for all I/O events to arrive
	$in_yield++;
	$::application-> yield;
	$in_yield = 0;

	my @ev;
	my @xr;
	while ( ( $fileno, $flags) = each %masks) {
		my $f = $filenos{$fileno};
		next unless $f;
		my @xr;

		my $lflags = 0;
		$lflags |= IO_READ      if $flags & fe::Read; 
		$lflags |= IO_WRITE     if $flags & fe::Write; 
		$lflags |= IO_EXCEPTION if $flags & fe::Exception; 
	
		for my $r ( @{$f-> {rec}}) {
			if ( $r-> [WATCH_IO_FLAGS] & $lflags) {
				$r-> [WATCH_IO_FLAGS] &= $lflags;
				push @ev, $r;
			} else {
				push @xr, $r;
			}
		}

		next if @xr == @{$f->{rec}};
		if ( @xr) {
			$f-> {rec} = \@xr;
			reset_mask( $f);
		} else {
			warn "$fileno object destroyed\n" if $DEBUG;
			$f-> {object}-> destroy if $f-> {object};
			delete $filenos{$fileno};
		}
	}

	my %timer = (map { $_ => undef } grep { defined $_-> [WATCH_DEADLINE] } @ev);
	if ( scalar keys %timer) {
		@timers = grep { not exists $timer{"$_"}} @timers;
		reset_timer();
	}
	if ( $DEBUG) {
		warn "io dispatch ", join(' ', map { defined($_) ? $_ : 'undef' } @$_), "\n"
			for @ev;
	}
	$$_[WATCH_OBJ]-> io_handler( $_) for @ev;
}

sub watch
{
	my ( $self, $rec) = @_;
	my $fileno = fileno $rec->[WATCH_IO_HANDLE]; 
	die "Invalid filehandle" unless defined $fileno;

	my $flags  = $rec->[WATCH_IO_FLAGS];

	unless ( $filenos{$fileno}) {
		my $f = Prima::File-> new(
			owner       => $::application,
			file        => $rec->[WATCH_IO_HANDLE],
			onRead      => \&on_read,
			onWrite     => \&on_write,
			onException => \&on_exception,
		);
		die "Error creating Prima::File:$@" unless $f;

		$filenos{$fileno} = {
			object   => $f,
			mask     => 0,
			rec      => [],
		};
		warn "object created for $fileno\n" if $DEBUG;
	}

	my $f = $filenos{$fileno};
	push @{$f-> {rec}}, $rec;
	reset_mask($f);

	$self-> after( $rec) if $rec-> [WATCH_DEADLINE];
}

sub deadline
{
	return undef unless @timers;
	my $new_deadline = $timers[0]-> [WATCH_DEADLINE];
	
	for ( map { $_-> [WATCH_DEADLINE] } @timers) {
		next if $_ >= $new_deadline;
		$new_deadline = $_;
	}
	return $new_deadline;
}

sub reset_timer
{
	$deadline = deadline();
	unless ( defined $deadline) {
		warn "stop timer\n" if $DEBUG;
		$timer-> stop if $timer;
		return;
	}

	my $timeout = $deadline - time;
	$timeout = 0.001 if $timeout < 0;
	$timeout = int( $timeout * 1000 + .5);

	$timer-> timeout( $timeout);
	$timer-> start;

	warn "start timer ", $timeout/1000, "\n" if $DEBUG;
}

sub on_tick
{
	warn "event timer\n" if $DEBUG;
	$event++;

	my @ev;
	my $t  = time;

	# timers
	push @ev, grep { $_-> [WATCH_DEADLINE] <= $t } @timers;
	@timers = grep { $_-> [WATCH_DEADLINE]  > $t } @timers;

	# files
	my @kill;
	while ( my ( $fileno, $r) = each %filenos) {
		my @xr = grep { 
			not defined($_-> [WATCH_DEADLINE]) or 
			($_-> [WATCH_DEADLINE] > $t) 
		} @{$r->{rec}};
		next if @xr == @{$r->{rec}};
		if ( @xr) {
			$r-> {rec} = \@xr;
			reset_mask( $r);
		} else {
			push @kill, $fileno;
		}
	}
	for ( @kill) {
		warn "$_ object destroyed\n" if $DEBUG;
		$filenos{$_}-> {object}-> destroy
			if $filenos{$_}-> {object};
		delete $filenos{$_};
	}

	reset_timer;

	$$_[WATCH_IO_FLAGS] = 0 for @ev;
	if ( $DEBUG) {
		warn "timer dispatch ", join(' ', map { defined($_) ? $_ : 'undef' } @$_), "\n"
			for @ev
	}
	$$_[WATCH_OBJ]-> io_handler( $_) for @ev;
}

sub after
{
	my ( $self, $rec) = @_;

	push @timers, $rec;
	unless ( $timer) {
		$timer = Prima::Timer-> create(
			owner  => $::application,
			onTick => \&on_tick,
			active => 0,
		);
		die "Error creating Prima::Timer:$@" unless $timer;
		warn "created global timer\n" if $DEBUG;
	}
	reset_timer;
}

sub empty { ( @timers + scalar keys %filenos) ? 0 : 1 }

sub yield
{
	warn "yield\n" if $DEBUG;
	my ( $self, $nonblocking ) = @_;
	local $event = 0;
	$::application-> yield;
	return if $nonblocking;
	$::application-> yield while $event == 0;
}

sub remove
{
	my ($self, $obj) = @_;

	my $t = @timers;
	@timers = grep { defined($_-> [WATCH_OBJ]) and $_-> [WATCH_OBJ] != $obj } @timers;
	reset_timer if $t != @timers;

	my @kill;
	while ( my ( $fileno, $r) = each %filenos) {
		my @xr = grep { defined($_-> [WATCH_OBJ]) and $_-> [WATCH_OBJ] != $obj } @{$r->{rec}};
		next if @xr == @{$r->{rec}};
		if ( @xr) {
			$r-> {rec} = \@xr;
			reset_mask( $r);
		} else {
			push @kill, $fileno;
		}
	}
	for ( @kill) {
		warn "$_ object destroyed\n" if $DEBUG;
		$filenos{$_}-> {object}-> destroy
			 if $filenos{$_}-> {object};
		delete $filenos{$_};
	}
}

1;
