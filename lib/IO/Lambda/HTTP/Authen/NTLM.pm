# $Id: NTLM.pm,v 1.3 2008/05/11 21:39:01 dk Exp $

package IO::Lambda::HTTP::Authen::NTLM;

use strict;
use Authen::NTLM;

use IO::Lambda qw(:all);

sub authenticate
{
	my ( $class, $self, $req, $response) = @_;

	lambda {
		# issue req phase 1
		my $tried_phase1;
		my $method = ($class =~ /:(\w+)$/)[0];
		
		ntlm_reset;
		ntlm_user( $self-> {username});
		ntlm_domain( $self-> {domain}) if defined $self-> {domain};

		my $r = $req-> clone;
		$r-> content('');
		$r-> header('Content-Length' => 0);
		$r-> header('Authorization'  => "$method " . ntlm());
				
		context $self-> handle_connection( $r);
	tail {
		my $answer = shift;
		return $answer unless ref($answer);

                return $answer if $tried_phase1 or $answer-> code != 401;
		my $challenge = $answer-> header('WWW-Authenticate') || '';
		return $answer unless $challenge =~ s/^$method //;

		# issue req phase 2
		ntlm_reset;
		ntlm();
		ntlm_user( $self-> {username});
		ntlm_password( $self-> {password});
		ntlm_domain( $self-> {domain}) if defined $self-> {domain};
		
		my $r = $req-> clone;
        	$r-> header('Authorization' => "$method ". ntlm($challenge));

		ntlm_reset;
		$tried_phase1++;
		context $self-> handle_connection( $r);
                return again;
	}}
}

1;

__DATA__

=pod

=head1 NAME

IO::Lambda::HTTP::Authen::NTLM - Library for enabling NTLM authentication (Microsoft) in IO::Lambda

=head1 SYNOPSIS

	use IO::Lambda qw(:all);
	use IO::Lambda::HTTP;
	
	my $req = HTTP::Request-> new( GET => "http://company.com/protected.html" );
	$req-> protocol('HTTP/1.1');
	$req-> headers-> header( Host => $req-> uri-> host);
	
	my $r = IO::Lambda::HTTP-> new(
		$req,
		username   => 'moo',
		password   => 'foo',
		keep_alive => 1,
	)-> wait;
	
	print ref($r) ? $r-> as_string : $r;

=head1 DESCRIPTION

IO::Lambda::HTTP::Authen::NTLM allows to authenticate against servers that are
using the NTLM authentication scheme popularized by Microsoft. This type of
authentication is common on intranets of Microsoft-centric organizations.

The module takes advantage of the Authen::NTLM module by Mark Bush. Since there
is also another Authen::NTLM module available from CPAN by Yee Man Chan with an
entirely different interface, it is necessary to ensure that you have the
correct NTLM module.

In addition, there have been problems with incompatibilities between different
versions of Mime::Base64, which Bush's Authen::NTLM makes use of. Therefore, it
is necessary to ensure that your Mime::Base64 module supports exporting of the
encode_base64 and decode_base64 functions.

=head1 SEE ALSO

L<IO::Lambda>, L<Authen::NTLM>. 

Description copy-pasted from L<LWP::Authen::Ntlm> by Gisle Aas.

=head1 AUTHOR

Dmitry Karasik, E<lt>dmitry@karasik.eu.orgE<gt>.


=cut
