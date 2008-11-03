# $Id: DBI.pm,v 1.1 2008/11/03 14:55:10 dk Exp $
package IO::Lambda::DBI;
use base qw(IO::Lambda::Message);

our $DEBUG = $ENV{IO_DBI_DEBUG};
our @EXPORT_OK = qw(message);

use strict;
use warnings;
use Storable qw(freeze thaw);
use IO::Lambda qw(:all);
use IO::Lambda::Thread;
use IO::Lambda::Message;

sub new
{
	my $class = shift;

	# XXX support other transports
	my $transport = IO::Lambda::Thread-> new(
		\&IO::Lambda::Message::worker,
		'IO::Lambda::Message::DBI',
	);
	$transport-> start;

	return $class-> SUPER::new($transport);
}

sub return_message
{
	my ( $self, $msg, $error) = @_;
	return ( undef, $error) if defined $error;
	($msg, $error) = $self-> decode( $msg);
	return ( undef, $error) if defined $error;
	return ( undef, "bad response") unless 
		$msg and ref($msg) and ref($msg) eq 'ARRAY' and @$msg > 0;

	return ( undef, @$msg) unless shift @$msg;

	# ok, finally
	return ( 1, @$msg);
}

sub dbi_message
{
	my ( $self, $method, $wantarray) = ( shift, shift, shift );
	$wantarray ||= 0;
	my ( $msg, $error) = $self-> encode([ $method, $wantarray, @_]);
	return lambda { $error } if $error;
	$self-> new_message( $msg );

}

sub connect { shift-> dbi_message('connect' => 0, @_) }
sub call    { shift-> dbi_message( call => wantarray, @_) }

sub disconnect
{
	my $self = $_[0];
	lambda {
		context $self-> dbi_message('disconnect');
	tail {
		my @d = @_;
		context $self-> {transport};
	tail {
		# XXX thread errors?
		return @d;
	}}}
}


package IO::Lambda::Message::DBI;
use base qw(IO::Lambda::Message::Simple);

use DBI;

sub connect
{
	my $self = shift;
	die "already connected" if $self-> {dbh};
	$self-> {dbh} = DBI-> connect(@_);
	return 1;
}

sub disconnect
{
	my $self = shift;
	die "not connected" unless $self-> {dbh};
	$self-> {dbh}-> disconnect;
	undef $self-> {dbh};
	$self-> quit;
	return 42;
}

sub call
{
	my ( $self, $method, @p) = @_;
	die "not connected" unless $self-> {dbh};
	return $self-> {dbh}-> $method(@p);
}

1;
