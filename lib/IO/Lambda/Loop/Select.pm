# $Id: Select.pm,v 1.11 2008/05/07 11:07:06 dk Exp $

package IO::Lambda::Loop::Select;
use strict;
use warnings;
use Errno qw(EINTR);
use IO::Lambda qw(:constants);
use Time::HiRes qw(time);

IO::Lambda::Loop::default('Select');

# IO::Select::select doesn't distinguish between select returning 0 and -1, don't have
# time to fix that. I'll just use a plain select instead, it'll be faster also.

sub new
{
	my $self = bless {} , shift;
	$self-> {$_}     = '' for qw(read write exc);
	$self-> {items}  = {};
	$self-> {timers} = [];
	return $self;
}

sub empty
{
	my $self = shift;
	return (
		@{$self->{timers}} + 
		keys(%{$self-> {items}})
	) ? 0 : 1;
}

sub yield
{
	my ( $self, $nonblocking ) = @_;

	return if $self-> empty;

	my $t;
	$t = 0 if $nonblocking;

	my ($min,$max) = ( 0, -1);
	my $ct  = time;

	# timers
	for ( @{$self-> {timers}}) {
		$t = $_->[WATCH_DEADLINE]
			if defined $_->[WATCH_DEADLINE] and 
			(!defined($t) or $t > $_-> [WATCH_DEADLINE]);
	}

	# handles
	my ( $R, $W, $E) = @{$self}{qw(read write exc)};

	while ( my ( $fileno, $bucket) = each %{ $self-> {items}} ) {
		for ( @$bucket) {
			$t = $_->[WATCH_DEADLINE]
				if defined $_->[WATCH_DEADLINE] and 
				(!defined($t) or $t > $_-> [WATCH_DEADLINE]);
		}
		$max = $fileno if $max < $fileno;
		$min = $fileno if !defined($min) or $min > $fileno;
	}
	if ( defined $t) {
		$t -= $ct;
		$t = 0 if $t < 0;
	}

	# do select
	my $n = select( $R, $W, $E, $t);
	if ( $n < 0) {
		if ( $! == EINTR) {
			# ignore
		} else {
			die "select() error:$!$^E" if $n < 0;
		}
	}
	
	# expired timers
	my ( @kill, @expired);

	$t = $self-> {timers};
	@$t = grep {
		($$_[WATCH_DEADLINE] <= $ct) ? do {
			push @expired, $_;
			0;
		} : 1;
	} @$t;

	# handles
	if ( $n > 0) {
		# process selected handles
		for ( my $i = $min; $i <= $max && $n > 0; $i++) {
			my $what = 0;
			if ( vec( $R, $i, 1)) {
				$what |= IO_READ;
				vec( $self-> {read}, $i, 1) = 0;
			}
			if ( vec( $W, $i, 1)) {
				$what |= IO_WRITE;
				vec( $self-> {write}, $i, 1) = 0;
			}
			if ( vec( $E, $i, 4)) {
				$what |= IO_EXCEPTION;
				vec( $self-> {exc}, $i, 1) = 0;
			}
			next unless $what;

			my $bucket = $self-> {items}-> {$i};
			@$bucket = grep {
				($$_[WATCH_IO_FLAGS] & $what) ? do {
					$$_[WATCH_IO_FLAGS] &= $what;
					push @expired, $_;
					0;
				} : 1;
			} @$bucket;
			delete $self-> {items}->{$i} unless @$bucket;
			$n--;
		}
	} else {
		# else process timeouts
		my @kill;
		while ( my ( $fileno, $bucket) = each %{ $self-> {items}}) {
			@$bucket = grep {
				(
					defined($_->[WATCH_DEADLINE]) && 
					$_->[WATCH_DEADLINE] <= $ct
				) ? do {
					$$_[WATCH_IO_FLAGS] = 0;
					push @expired, $_;
					0;
				} : 1;
			} @$bucket;
			push @kill, $fileno unless @$bucket;
		}
		delete @{$self->{items}}{@kill};
		$self-> rebuild_vectors;
	}
		
	# call them
	$$_[WATCH_OBJ]-> io_handler( $_) for @expired;
}

sub watch
{
	my ( $self, $rec) = @_;
	my $fileno = fileno $rec->[WATCH_IO_HANDLE]; 
	die "Invalid filehandle" unless defined $fileno;
	my $flags  = $rec->[WATCH_IO_FLAGS];

	vec($self-> {read},  $fileno, 1) = 1 if $flags & IO_READ;
	vec($self-> {write}, $fileno, 1) = 1 if $flags & IO_WRITE;
	vec($self-> {exc},   $fileno, 1) = 1 if $flags & IO_EXCEPTION;

	push @{$self-> {items}-> {$fileno}}, $rec;
}

sub after
{
	my ( $self, $rec) = @_;
	push @{$self-> {timers}}, $rec;
}

sub remove
{
	my ($self, $obj) = @_;

	@{$self-> {timers}} = grep { 
		defined($_->[WATCH_OBJ]) and $_->[WATCH_OBJ] != $obj 
	} @{$self-> {timers}};

	my @kill;
	while ( my ( $fileno, $bucket) = each %{$self->{items}}) {
		@$bucket = grep { defined($_->[WATCH_OBJ]) and $_->[WATCH_OBJ] != $obj } @$bucket;
		next if @$bucket;
		push @kill, $fileno;
	}
	delete @{$self->{items}}{@kill};

	$self-> rebuild_vectors;
}

sub remove_event
{
	my ($self, $rec) = @_;
	
	@{$self-> {timers}} = grep { $_ != $rec } @{$self-> {timers}};

	my @kill;
	while ( my ( $fileno, $bucket) = each %{$self->{items}}) {
		@$bucket = grep { $_ != $rec } @$bucket;
		next if @$bucket;
		push @kill, $fileno;
	}
	delete @{$self->{items}}{@kill};

	$self-> rebuild_vectors;

}

sub rebuild_vectors
{
	my $self = $_[0];
	$self-> {$_} = '' for qw(read write exc);
	my $r = \ $self-> {read};
	my $w = \ $self-> {write};
	my $e = \ $self-> {exc};
	while ( my ( $fileno, $bucket) = each %{$self->{items}}) {
		for my $flags ( map { $_-> [WATCH_IO_FLAGS] } @$bucket) {
			vec($$r, $fileno, 1) = 1 if $flags & IO_READ;
			vec($$w, $fileno, 1) = 1 if $flags & IO_WRITE;
			vec($$e, $fileno, 1) = 1 if $flags & IO_EXCEPTION;
		}
	}
}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::Loop::Select - select(2)-based event loop for IO::Lambda

=head1 DESCRIPTION

This is the default implementation of event loop for IO::Lambda. IO::Lambda is
designed to be agnostic of event loop choice, but this one is the default,
reference implementation. The module is not intended for direct use. The
documentation declares the event loop interface rather than explains
specificities of the module.

=head1 SYNOPSIS

  use IO::Lambda::Loop::Select; # explicitly select the event loop module
  use IO::Lambda;

=head1 API

=over

=item new

Creates new instance of C<IO::Lambda::Loop::Select>.

=item after $RECORD

Stores the timeout record. The timeout record is an array, with the following
layout: [ $OBJECT, $DEADLINE, $CALLBACK ]. Loop will invoke
C<IO::Lambda::io_handler> on C<$OBJECT> after C<$DEADLINE> is expired.

=item empty

Returns TRUE if there are no records in the loop, FALSE otherwise.

=item remove $OBJECT

Removes all records associated with C<$OBJECT>.

=item remove_event $EVENT

Removes a single events

=item watch $RECORD

Stores the IO record. The IO record in an array, with the following 
layout: [ $OBJECT, $DEADLINE, $CALLBACK, $HANDLE, $FLAGS ]. Loop will
invoke C<IO::Lambda::io_handler> on C<$OBJECT> either when C<$HANDLE>
becomes readable/writable etc, depending on C<$FLAGS>, or after C<$DEADLINE>
is expired. C<$DEADLINE> can be undef, meaning no timeout. C<$FLAGS> is 
a combination of C<IO_READ>, C<IO_WRITE>, and C<IO_EXCEPTION> values.

=item yield

Waits for at least one of the stored record to become active, dispatches
events to C<IO::Lambda::io_handler> for the records that have, then removes
these records. The invoker must resubmit records in order continue receiving
new events.

=back

=cut
