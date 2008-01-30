# $Id $

package IO::Lambda::Loop::AnyEvent;
use strict;
use warnings;
use AnyEvent;
use IO::Lambda qw(:constants);
use Time::HiRes qw(time);

my @records;

IO::Lambda::Loop::default('AnyEvent');

sub new   { bless {} , shift }
sub empty { scalar(@records) ? 0 : 1 }

sub watch
{
	my ( $self, $rec) = @_;

	my $flags  = $rec->[WATCH_IO_FLAGS];
	my $poll = '';
	$poll .= 'r' if $flags & IO_READ;
	$poll .= 'w' if $flags & IO_WRITE;
	
	if ( $flags & IO_EXCEPTION) {
		warn "** warning: AnyEvent doesn't support IO_EXCEPTION\n";

		unless ( length $poll) {
			# emulate IO_EXCEPTION that will eventually expire
			return $self-> after( $rec) 
				if defined $rec-> [WATCH_DEADLINE];
			# emulate IO_EXCEPTION that will never come
			push @$rec, 0;
			push @records, $rec;
			return;
		}
	}
	
	push @records, $rec;
	
	push @$rec, AnyEvent-> io(
		fh    => $rec-> [WATCH_IO_HANDLE],
		poll  => $poll,
		cb    => sub {
			my $nr = @records;
			@records = grep { $_ != $rec } @records;
			return if $nr == @records;

			$nr = pop @$rec;
			pop @$rec while $nr--;

			$rec-> [WATCH_IO_FLAGS] = ( $_[0] eq 'r') ? IO_READ : IO_WRITE;
			$rec-> [WATCH_OBJ]-> io_handler($rec)
				if $rec->[WATCH_OBJ];
		}
	);

	if ( defined $rec->[WATCH_DEADLINE]) {
		push @$rec, AnyEvent-> timer(
			after  => $rec-> [WATCH_DEADLINE] - time,
			cb     => sub {
				my $nr = @records;
				@records = grep { $_ != $rec } @records;
				return if $nr == @records;

				$nr = pop @$rec;
				pop @$rec while $nr--;

				$rec-> [WATCH_IO_FLAGS] = 0;
				$rec-> [WATCH_OBJ]-> io_handler($rec)
					if $rec->[WATCH_OBJ];
			}
		);
		push @$rec, 2;
	} else {
		push @$rec, 1;
	}
}

sub after
{
	my ( $self, $rec) = @_;

	push @records, $rec;
	push @$rec, AnyEvent-> timer(
		after  => $rec-> [WATCH_DEADLINE] - time,
		cb     => sub {
			my $nr = @records;
			@records = grep { $_ != $rec } @records;
			return if $nr == @records;

			pop @$rec;
			pop @$rec;

			$rec-> [WATCH_OBJ]-> io_handler($rec)
				if $rec->[WATCH_OBJ];
		},
	), 1;
}

sub yield
{
	AnyEvent-> one_event;
}

sub remove
{
	my ($self, $obj) = @_;

	my @r;
	for ( @records) {
		next unless $_-> [WATCH_OBJ];
		if ( $_->[WATCH_OBJ] == $obj) {
			my $nr = pop @$_;
			pop @$_ while $nr--;
		} else {
			push @r, $_;
		}
	}

	@records = @r;
}

1;
