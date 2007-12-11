# $Id: Select.pm,v 1.1 2007/12/11 14:48:38 dk Exp $

package IO::Lambda::Loop::Select;
use strict;
use warnings;
use IO::Lambda qw(:all);

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

sub yield
{
	my ( $self, $nonblocking ) = @_;

	my $t;
	$t = 0 if $nonblocking;

	my ($min,$max) = ( undef, 0);
	my $ct  = time;

	# timers
	for ( @{$self-> {timers}}) {
		$t = $_->[1]
			if defined $_->[1] and (!defined($t) or $t > $_-> [1]);
	}

	# handles
	my ( $R, $W, $E) = @{$self}{qw(read write exc)};

	while ( my ( $fileno, $ticket) = each %{ $self-> {items}} ) {
		$t = $ticket->[1]
			if defined $ticket->[1] and (!defined($t) or $t > $ticket-> [1]);
		$max = $fileno if $max < $fileno;
		$min = $fileno if !defined($min) or $min > $fileno;
	}
	if ( defined $t) {
		$t -= $ct;
		$t = 0 if $t < 0;
	}

	# do select
	my $n  = select( $R, $W, $E, $t);
	die "select() error:$!" unless defined $n;
	
	# expired timers
	my @expired_timers;
	$t = $self-> {timers};
	@$t = map { ( $_-> [1] > $ct) ? $_ : ( push @expired_timers, $_ and ()) } @$t;

	# handles
	my @expired_handles;
	if ( $n > 0) {
		my %what;
		for ( my $i = $min; $i <= $max && $n > 0; $i++) {
			my $what = 0;
			if ( vec( $R, $i, 1)) {
				$what |= FH_READ;
				vec( $self-> {read}, $i, 1) = 0;
			}
			if ( vec( $W, $i, 1)) {
				$what |= FH_WRITE;
				vec( $self-> {write}, $i, 1) = 0;
			}
			if ( vec( $E, $i, 4)) {
				$what |= FH_EXCEPTION;
				vec( $self-> {exc}, $i, 1) = 0;
			}
			next unless $what;
			push @expired_handles, $i;
			push @{ $self-> {items}-> {$i} }, $what;
			$n--;
		}
	} else {
		while ( my ( $fileno, $ticket) = each %{ $self-> {items}}) {
			next if !defined($ticket->[1]) || $ticket->[1] > $ct;
			push @expired_handles, $fileno;
			push @$ticket, 0; # if not a timeout, this is a 1|2|4 combination
			vec( $self-> {read},  $fileno, 1) = 0;
			vec( $self-> {write}, $fileno, 1) = 0;
			vec( $self-> {exc},   $fileno, 1) = 0;
		}
	}
	@expired_handles = delete @{$self-> {items}}{@expired_handles};
		
	# call them
	for ( @expired_handles) {
		my $flags = pop @$_;
		$$_[2]-> callback_handle( $flags, @$_[0,3..$#$_]);
	}
	for ( @expired_timers) {
		$$_[2]-> callback_timer( @$_[3..$#$_]);
	}
}

sub run
{
	my $self = $_[0];
	$self-> yield while 
		@{$self->{timers}} + keys %{$self-> {items}};
}

sub watch
{
	my ( $self, $flags, $handle, $deadline, $obj, @param) = @_;
	my $fileno = fileno $handle; 
	die "Invalid filehandle" unless defined $fileno;

	vec($self-> {read},  $fileno, 1) = 1 if $flags & FH_READ;
	vec($self-> {write}, $fileno, 1) = 1 if $flags & FH_WRITE;
	vec($self-> {exc},   $fileno, 1) = 1 if $flags & FH_EXCEPTION;
	$self-> {items}-> {$fileno} = [
		$handle,
		$deadline,
		$obj,
		@param
	];
}

sub after
{
	my ( $self, $deadline, $obj, @param) = @_;
	push @{ $self-> {timers}}, [
		undef,
		$deadline,
		$obj,
		@param,
	];
}

sub remove
{
	my ( $self, $obj) = @_;

	@{ $self-> {timers}} = grep { $obj != $$_[2] } @{ $self-> {timers}};
	my @kill;
	while ( my ( $fileno, $ticket) = each %{$self->{items}}) {
		next if not defined($ticket->[2]) or $ticket->[2] != $obj;
		push @kill, $fileno;
		vec($self-> {$_},  $fileno, 1) = 0 for qw(read write exc);
	}
	delete @{$self->{items}}{@kill};
}

1;
