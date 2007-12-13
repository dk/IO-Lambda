# $Id: Select.pm,v 1.3 2007/12/13 23:09:01 dk Exp $

package IO::Lambda::Loop::Select;
use strict;
use warnings;
use IO::Lambda qw(:constants);

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
	return (@{$self->{timers}} + keys %{$self-> {items}}) ? 0 : 1;
}

sub yield
{
	my ( $self, $nonblocking ) = @_;

	return if $self-> empty;

	my $t;
	$t = 0 if $nonblocking;

	my ($min,$max) = ( undef, 0);
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
	my $n  = select( $R, $W, $E, $t);
	die "select() error:$!$^E" if $n < 0;
	
	# expired timers
	my ( @kill, @expired);

	$t = $self-> {timers};
	@$t = grep {
		($$_[WATCH_DEADLINE] >= $ct) ? do {
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
					$_->[WATCH_DEADLINE] >= $ct
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
