package Slim::Utils::OSDetect;


# Logitech Media Server Copyright 2001-2024 Logitech.
# Lyrion Music Server Copyright 2024 Lyrion Community.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

=head1 NAME

Slim::Utils::OSDetect

=head1 DESCRIPTION

L<Slim::Utils::OSDetect> handles Operating System Specific details.

=head1 SYNOPSIS

	if (Slim::Utils::OSDetect::isWindows()) {

=cut

use strict;
use FindBin qw($Bin);

my ($os, $isWindows, $isMac, $isLinux);

=head1 METHODS

=head2 OS( )

returns a string to indicate the detected operating system currently running Lyrion Music Server.

=cut

sub OS {
	__PACKAGE__->init->name;
}

=head2 init( $newBin)

 Figures out where the preferences file should be on our platform, and loads it.

=cut

sub init {
	my $newBin = shift;

	if ($os) {
		return $os;
	}

	# Allow the caller to pass in a new base dir (for test cases);
	if (defined $newBin && -d $newBin) {
		$Bin = $newBin;
	}

	# Let's see whether there's a custom OS file (to be used by 3rd party NAS vendors etc.)
	eval {
		require Slim::Utils::OS::Custom;
		$os = Slim::Utils::OS::Custom->new();
		#print STDOUT "Found custom OS support file for " . $os->name . "\n";
	};

	if ( $@ && $@ !~ m{^Can't locate Slim/Utils/OS/Custom.pm} ) {
		warn $@;
	}

	if (!$os) {

		if ($^O =~/darwin/i) {

			require Slim::Utils::OS::OSX;
			$os = Slim::Utils::OS::OSX->new();

		} elsif ($^O =~ /^m?s?win/i) {

			require Slim::Utils::OS::Win32;
			if (Slim::Utils::OS::Win32->getFlavor() eq 'Win64') {
				require Slim::Utils::OS::Win64;
				$os = Slim::Utils::OS::Win64->new();
			}
			else {
				$os = Slim::Utils::OS::Win32->new();
			}

		} elsif ($^O =~ /linux/i) {

			require Slim::Utils::OS::Linux;
			$os = Slim::Utils::OS::Linux->getFlavor();

			# we only differentiate Debian/Suse/Red Hat if they've been installed from a package
			if ($os =~ /debian/i && $0 =~ m{^/usr/sbin/squeezeboxserver}) {

				require Slim::Utils::OS::Debian;
				$os = Slim::Utils::OS::Debian->new();

			} elsif ($os =~ /red hat/i && $0 =~ m{^/usr/libexec/squeezeboxserver}) {

				require Slim::Utils::OS::RedHat;
				$os = Slim::Utils::OS::RedHat->new();

			} elsif ($os =~ /suse/i && $0 =~ m{^/usr/libexec/squeezeboxserver}) {

				require Slim::Utils::OS::Suse;
				$os = Slim::Utils::OS::Suse->new();

			} elsif ($os =~ /Synology/i) {

				require Slim::Utils::OS::Synology;
				$os = Slim::Utils::OS::Synology->new();

			} else {

				$os = Slim::Utils::OS::Linux->new();
			}

		} else {

			require Slim::Utils::OS::Unix;
			$os = Slim::Utils::OS::Unix->new();

		}
	}

	$os->initDetails();
	$isWindows = $os->name eq 'win';
	$isMac     = $os->name eq 'mac';
	$isLinux = $os->get('os') eq 'Linux';
	return $os;
}

{
	no strict qw(refs);
	*getOS = \&init;
}
#sub getOS {
#	__PACKAGE__->init;
#}

=head2 Backwards compatibility

 Keep some helper functions for backwards compatibility.

=cut

sub dirsFor {
	__PACKAGE__->init->dirsFor(shift);
}

sub details {
	__PACKAGE__->init->details();
}

sub getProxy {
	__PACKAGE__->init->getProxy();
}

sub skipPlugins {
	__PACKAGE__->init->skipPlugins();
}

=head2 isDebian( )

 The Debian package has some specific differences for file locations.
 This routine needs no args, and returns 1 if Debian distro is detected, with
 a clear sign that the .deb package has been installed, 0 if not.

=cut

sub isDebian {
	__PACKAGE__->init->get('isDebian');
}

sub isRHorSUSE {
	__PACKAGE__->init->get('isRedHat', 'isSuse');
}

sub isWindows {
	return $isWindows;
}

sub isMac {
	return $isMac;
}

sub isLinux {
	return $isLinux;
}

1;

__END__
