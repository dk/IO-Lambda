# $Id: DBI.pm,v 1.14 2009/01/10 14:29:30 dk Exp $
package IO::Lambda::DBI::Storable;

use Storable qw(freeze thaw);

my $DEBUG_DUMP = (($IO::Lambda::DEBUG{dbi} || 0) > 1);
require Data::Dumper if $DEBUG_DUMP;

sub encode
{
	my $self = $_[0];

	return Data::Dumper::Dumper($_[1]) if $DEBUG_DUMP;

	my $msg;
	eval { $msg = freeze( $_[1] ) };
	return $@ ? ( undef, $@) : $msg;
}

sub decode 
{
	my $self = $_[0];

	if ( $DEBUG_DUMP) {
		my $VAR1;
		eval { eval $_[1] };
		return $@ ? ( undef, $@) : $VAR1;
	}

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
use Carp;
use IO::Lambda qw(:all :dev);
use IO::Lambda::Message;

sub _d { "dbi(" . _o($_[0]) . ")" }

sub outcoming
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
	return $self-> new_message( $msg, $self-> {timeout} );
}

sub connect    { shift-> dbi_message( connect    => 0,         @_) }
sub disconnect { shift-> dbi_message( disconnect => 0,         @_) }
sub call       { shift-> dbi_message( call       => wantarray, @_) }
sub set_attr   { shift-> dbi_message( set_attr   => 0, @_) }
sub get_attr   { shift-> dbi_message( get_attr   => wantarray, @_) }

sub prepare
{
	my ( $self, $stmt) = @_;
	lambda {
		context $self-> dbi_message( prepare => 0, $stmt);
	tail {
		my ($error, $obj_id) = @_;
		return $error if defined $error;
		return IO::Lambda::DBI::Statement-> new($self, $obj_id);
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

package IO::Lambda::DBI::Statement;

sub new
{
	my ( $class, $owner, $obj_id) = @_;
	return bless {
		owner => $owner,
		id    => $obj_id,
	}, $class;
}

sub DESTROY {}

sub AUTOLOAD
{
	use vars qw($AUTOLOAD);
	my $method = $AUTOLOAD;
	$method =~ s/^.*:://;
	my $self = shift;

	return $self-> {owner}-> dbi_message( 
		execute => wantarray, 
		$method, $self-> {id},
		@_
	);
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
	die "already connected\n" if $self-> {dbh};
	$self-> {dbh} = DBI-> connect(@_);
	return $DBI::errstr unless $self-> {dbh};
	$self-> {prepared} = {};
	return undef;
}

sub disconnect
{
	my $self = shift;
	die "not connected\n" unless $self-> {dbh};
	my @r = $self-> {dbh}-> disconnect;
	undef $self-> {dbh};
	$self-> quit;
	return @r;
}

sub call
{
	my ( $self, $method, @p) = @_;
	die "not connected\n" unless $self-> {dbh};
	return $self-> {dbh}-> $method(@p);
}

sub set_attr
{
	my ( $self, %attr) = @_;
	die "not connected\n" unless $self-> {dbh};
	while ( my ( $k, $v) = each %attr) {
		$self-> {dbh}-> {$k} = $v;
	}
}

sub get_attr
{
	my ( $self, @keys) = @_;
	die "not connected\n" unless $self-> {dbh};
	return @{$self->{dbh}}{@keys};

}

sub prepare
{
	my ( $self, $stmt) = @_;
	die "not connected\n" unless $self-> {dbh};
	
	my $s = $self-> {dbh}-> prepare($stmt);
	return $self-> {dbh}-> errstr unless $s;

	$self-> {prepared}-> {"$s"} = $s;
	return "$s";
}

sub execute
{
	my ( $self, $method, $stmt, @p) = @_;
	
	die "not connected\n" unless $self-> {dbh};
	die "no such prepared statement\n" unless $self-> {prepared}->{$stmt};

	return $self-> {prepared}-> {$stmt}-> $method(@p);
}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::DBI - asynchronous DBI

=head1 DESCRIPTION

The module implements asynchronous DBI proxy object, that remotes DBI calls
using any given file handle, such as stream sockets, pipes, etc. All calls to
DBI methods are implemented as method calls to the object, which return
lambdas, that shall be subsequently called and awaited for completion.

=head1 SYNOPSIS

    use IO::Lambda qw(:all);
    use IO::Lambda::DBI;
    use IO::Lambda::Thread qw(new_thread);

    # use threads as a transport
    my ($thread, $socket) = new_thread( sub {
        my $socket = shift;
        IO::Lambda::Message::DBI-> new( $socket, $socket )-> run;
    }, 1);
	
    my $dbi = IO::Lambda::DBI-> new($socket, $socket);

    # execute a query
    print lambda {
        context $dbi-> connect('DBI:mysql:database=mysql', '', '');
    tail {
        return "connect error:$_[0]" unless shift;
        context $dbi-> selectrow_array('SELECT 5 + ?', {}, 2);
    tail {
        my ($ok,$result) = @_;
        return "dbi error:$result" unless $ok;
        context $dbi-> disconnect;
    tail {
        return "select=$result";
    }}}}-> wait, "\n";

    # finalize
    $thread-> join;

=head1 IO::Lambda::DBI

All remoted methods return lambdas of type

   dbi_result :: () -> ( 1, @result | 0, $error )

where depending on the first returned item in the array, the other items are
either DBI method results, or an error.

The class handles AUTOLOAD methods as proxy methods, so calls such as
C<< $dbh-> selectrow_array >> are perfectly legal.

=over

=item new $class, $r, $w, %options

See L<IO::Lambda::Message/new>.

=item connect($dsn, $user, $auth, %attr) :: dbi_result

Proxies C<DBI::connect>. In case of failure, depending on C<RaiseError> flag,
returns either C<(0,$error)> or C<(1,$error)>.

=item disconnect :: dbi_result

Proxies C<DBI::disconnect>.

=item call($method, @parameters) :: dbi_result

Proxies C<DBI::$method(@parameters)>.

=item set_attr(%attr)

Sets attributes on a DBI handle.

=item get_attr(@keys)

Retrieves values for attribute keys from a DBI handle.

=item prepare($statement)

Returns a new prepared statement object or an error string.
All method calls on this object return lambda that also
wait until remote methods are executed.

=back

=head1 IO::Lambda::Message::DBI

Descendant of C<IO::Lambda::Message::Simple>. Implements
blocking, server side that does the actual calls to the DBI.

=head1 BUGS

C<DBI::prepare> is not tested.

=head1 SEE ALSO

L<DBI>, F<eg/dbi.pl>.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
