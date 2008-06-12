# $Id: NTLM.pm,v 1.4 2008/06/12 13:18:27 dk Exp $

package IO::Lambda::HTTP::Authen::NTLM;

use strict;
use Authen::NTLM;

use IO::Lambda qw(:all);

*ntlmv2 = sub { die "NTLMv2 requires Authen::NTLM v1.04 or higher" if shift } if $Authen::NTLM::VERSION < 1.04;

sub authenticate
{
	my ( $class, $self, $req, $response) = @_;

	lambda {
		# issue req phase 1
		my $tried_phase1;
		my $method = ($class =~ /:(\w+)$/)[0];
		
		ntlm_reset;
		ntlm_user( $self-> {username});
		ntlm_domain( defined($self->{domain}) ? $self-> {domain} : "");
		ntlmv2(($self-> {ntlm_version} > 1) ? 1 : 0);

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
		ntlmv2(( $self-> {ntlm_version} > 1) ? 1 : 0);
		ntlm();
		ntlm_user( $self-> {username});
		ntlm_password( $self-> {password});
		ntlm_domain( defined($self->{domain}) ? $self-> {domain} : "");
		
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
