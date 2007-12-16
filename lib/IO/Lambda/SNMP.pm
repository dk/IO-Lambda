# $Id: SNMP.pm,v 1.2 2007/12/16 20:20:16 dk Exp $
package IO::Lambda::SNMP;
use vars qw(@ISA @EXPORT_OK %EXPORT_OK);
@ISA = qw(Exporter);
my @methods = qw(get fget getnext fgetnext set bulkwalk);
@EXPORT_OK = map { "snmp$_" } @methods;
%EXPORT_TAGS = ( all => \@EXPORT_OK);

use strict;
use warnings;
use SNMP;
use IO::Handle;
use Exporter;
use Time::HiRes qw(time);
use IO::Lambda qw(:all :constants);
use IO::Lambda::Loop::Select;

$IO::Lambda::Loop::Select::SELECT = sub {
	my ( $r, $w, $e, $t) = @_;
	SNMP::MainLoop(1e-6);
	my ( $timeout, @fds) = SNMP::select_info;
	$t = $timeout if not(defined $t) or $t > $timeout;
	vec($$r, $_, 1) = 1 for @fds;
	return select( $$r, $$w, $$e, $t);
};

$IO::Lambda::Loop::Select::GETNUMFDS = sub {
	my ( $timeout, @fds) = SNMP::select_info;
	return scalar @fds;
};

sub snmpcallback
{
	my ($q, $c) = (shift, shift);
	$q-> resolve($c);
	$q-> terminate(@_);
	undef $c;
	undef $q;
}

sub wrapper
{
	my ( $cb, $method, $ref) = @_;
	my ( $session, @param ) = context;

	my $q = IO::Lambda-> new;
	my $c = $q-> bind;

	$session-> $method(
		@param, 
		[ \&snmpcallback, $q, $c ]
	);

	this-> add_tail( 
		$cb,
		$ref,
		$q,
		context
	);
}

for ( @methods) {
	eval "sub snmp$_(&) { wrapper( shift, '$_', \\&snmp$_ ) }";
	die $@ if $@;
}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::SNMP - snmp requests lambda style

=head1 DESCRIPTION

The module exports a set of lambdas: snmpget snmpfget snmpgetnext snmpfgetnext
snmpset snmpbulkwalk, that behave like the corresponding SNMP:: non-blocking
counterpart functions. See L<SNMP> for descriptions of their parameters and
results.

=head1 SYNOPSIS

   use strict;
   use SNMP;
   use IO::Lambda::SNMP qw(:all);
   use IO::Lambda qw(:all);
   
   my $sess = SNMP::Session-> new(
      DestHost => 'localhost',
      Community => 'public',
      Version   => '2c',
   );
   
   this lambda {
      context $sess, new SNMP::Varbind;
      snmpgetnext {
         my $vb = shift;
         print @{$vb->[0]}, "\n" ; 
         context $sess, $vb;
         again unless $sess-> {ErrorNum};
      }
   };
   this-> wait;

=head1 SEE ALSO

L<IO::Lambda>, L<SNMP>.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.

=cut
