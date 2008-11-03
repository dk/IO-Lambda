# $Id: DBI.pm,v 1.2 2008/11/03 20:58:27 dk Exp $
package IO::Lambda::DBI;
use base qw(IO::Lambda::Message);

our $DEBUG = $IO::Lambda::DEBUG{dbi};
our @EXPORT_OK = qw(message);

use strict;
use warnings;
use IO::Lambda qw(:all :dev);
use IO::Lambda::Thread;
use IO::Lambda::Message;

sub _d { "dbi(" . _o($_[0]) . ")" }

sub new
{
	my $class = shift;

	# XXX support other transports
	my $transport = IO::Lambda::Thread-> new(
		\&IO::Lambda::Message::worker,
		'IO::Lambda::Message::DBI',
	);
	$transport-> start;

	my $self = $class-> SUPER::new($transport);
	warn "new ", _d($self) . "\n" if $DEBUG;
	return $self;
}

sub return_message
{
	my ( $self, $msg, $error) = @_;
	if ( defined $error) {
		warn _d($self), " error: $error\n" if $DEBUG;
		return ( undef, $error);
	}

	($msg, $error) = $self-> decode( $msg);
	if ( defined $error) {
		warn _d($self), " error: $error\n" if $DEBUG;
		return ( undef, $error);
	}

	unless ( $msg and ref($msg) and ref($msg) eq 'ARRAY' and @$msg > 0) {
		warn _d($self), " error: bad response($msg)\n" if $DEBUG;
		return ( undef, "bad response");
	}

	unless ( shift @$msg) {
		warn _d($self), " error: @$msg\n" if $DEBUG;
		return ( undef, @$msg);
	}

	# ok, finally
	warn _d($self), " < ok: @$msg\n" if $DEBUG;
	return ( 1, @$msg);
}

sub dbi_message
{
	my ( $self, $method, $wantarray) = ( shift, shift, shift );
	$wantarray ||= 0;
	my ( $msg, $error) = $self-> encode([ $method, $wantarray, @_]);
	return lambda { $error } if $error;
	warn _d($self) . " > $method(@_)\n" if $DEBUG;
	$self-> new_message( $msg );

}

sub connect { shift-> dbi_message( connect => 0, @_) }
sub call    { shift-> dbi_message( call    => wantarray, @_) }

sub disconnect
{
	my $self = $_[0];
	lambda {
		context $self-> dbi_message('disconnect');
	tail {
		return @_ if $self-> {transport}-> is_stopped;
		context $self-> {transport};
		&tail();
	}}
}

sub DESTROY {}

sub AUTOLOAD
{
	use vars qw($AUTOLOAD);
	my $method = $AUTOLOAD;
	$method =~ s/^.*:://;
	shift-> dbi_message( call => wantarray, $method, @_);
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