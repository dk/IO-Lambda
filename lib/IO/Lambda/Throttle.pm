package IO::Lambda::Throttle;
use strict;
use warnings;
use Exporter;
use IO::Lambda qw(:all);
use IO::Lambda::Mutex qw(mutex);
use Time::HiRes qw(time);
use Scalar::Util qw(weaken);
our $DEBUG = $IO::Lambda::DEBUG{throttle} || 0;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(throttle);
our %EXPORT_TAGS = ( all => \@EXPORT_OK);

sub new
{
	my ($class, $rate, $strict) = @_;
	my $self = bless {
		mutex     => IO::Lambda::Mutex-> new,
		last      => 0,
		low       => 0,
		high      => 0,
		strict    => $strict || 0,
	}, $class;
	$self-> rate($rate);
	return $self;
}

sub rate
{
	return $_[0]-> {rate} unless $#_;
	my ( $self, $rate) = @_;
	die "negative rate" if defined($rate) and $rate < 0;
	$self-> {rate} = $rate;
}

sub strict { $#_ ? $_[0]-> {strict} = $_[1] : $_[0]-> {strict} }

# warning: when called, changes internal state of an object
# returns 0 if rate limitter thinks it's ok to run now,
# otherwise returns number of seconds needed to sleep
sub next_timeout
{
	my $self = shift;
	unless ( $self-> {rate}) {
		# special case
		return 0;
	}

	my $ts = time;
	if ( $ts < $self-> {last}) {
		# warn "negative time detected\n";
		my $delta = $self-> {last} - $ts;
		$self-> {low}  -= $delta;
		$self-> {high} -= $delta;
	}
	$self-> {last} = $ts;
	# warn "$ts: $self->{low}/$self->{high}\n";

	if ( $self-> {low} < $self-> {high}) {
		$self-> {low} += 1 / $self-> {rate};
		# warn "case1\n";
		return 0;
	} elsif ( $self-> {low} < $ts) {
		$self-> {low}  = $ts + 1 / $self-> {rate};
		$self-> {high} = $ts + ($self->{strict} ? 1 / $self-> {rate} : 1);
		# warn "case2\n";
		return 0;
	} else {
		# warn "wait ", $self->{low}-$ts, "\n";
		return $self-> {low} - $ts;
	}
}

# Returns a lambda that finishes until rate-limitter allows further run.
sub lock
{
	my $self = shift;
	weaken $self;
	return $self-> {mutex}-> pipeline( 
		lambda {
			my $timeout = $self-> next_timeout;
			return unless $timeout;
			context $timeout;
			timeout {
				die "something wrong, non-zero timeout"
					if $self-> next_timeout;
				return;
			};
		} 
	);
}

# returns a lambda that is finished when all lambdas, one by one,
# are passed through a rate limitter
sub ratelimit
{
	my ($self) = @_;
	return lambda {
		my @lambdas = @_;
		return unless @lambdas;
		context $self-> lock;
		tail {
			context shift @lambdas;
		tail {
			this-> call(@lambdas)-> start;
		}}
	};
}


sub throttle { __PACKAGE__-> new(@_)-> ratelimit }

1;
