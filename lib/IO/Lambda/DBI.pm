# $Id: DBI.pm,v 1.5 2008/11/04 17:52:27 dk Exp $
package IO::Lambda::DBI::Storable;

use Storable qw(freeze thaw);

sub encode
{
	my $self = $_[0];
	my $msg;
	eval { $msg = freeze( $_[1] ) };
	return $@ ? ( undef, $@) : $msg;
}

sub decode 
{
	my $self = $_[0];
	my $msg;
	eval { $msg = thaw( $_[1] ); };
	return $@ ? ( undef, $@) : $msg;
}

package IO::Lambda::DBI;
use base qw(
	IO::Lambda::Message
	IO::Lambda::DBI::Storable
);

our $DEBUG = $IO::Lambda::DEBUG{dbi};

use strict;
use warnings;
use IO::Lambda qw(:all :dev);
use IO::Lambda::Message;

sub _d { "dbi(" . _o($_[0]) . ")" }

sub parse
{
	my ( $self, $msg) = @_;
	my $error;

	($msg, $error) = $self-> decode( $msg);
	if ( defined $error) {
		warn _d($self), " error: $error\n" if $DEBUG;
		return ( undef, $error);
	}

	unless ( $msg and ref($msg) and ref($msg) eq 'ARRAY' and @$msg > 0) {
		warn _d($self), " error: bad response($msg)\n" if $DEBUG;
		return ( undef, "bad response");
	}

	# remote eval failed, or similar
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

sub connect    { shift-> dbi_message( connect    => 0,         @_) }
sub disconnect { shift-> dbi_message( disconnect => 0,         @_) }
sub call       { shift-> dbi_message( call       => wantarray, @_) }

sub DESTROY {}

sub AUTOLOAD
{
	use vars qw($AUTOLOAD);
	my $method = $AUTOLOAD;
	$method =~ s/^.*:://;
	shift-> dbi_message( call => wantarray, $method, @_);
}

package IO::Lambda::Message::DBI;
use base qw(
	IO::Lambda::Message::Simple
	IO::Lambda::DBI::Storable
);

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
	my @r = $self-> {dbh}-> disconnect;
	undef $self-> {dbh};
	$self-> quit;
	return @r;
}

sub call
{
	my ( $self, $method, @p) = @_;
	die "not connected" unless $self-> {dbh};
	return $self-> {dbh}-> $method(@p);
}

1;
