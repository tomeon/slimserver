#!/usr/bin/perl -w

# $Id$
#
# This is an installer program for perl modules which are required by Squeezebox Server,
# but for which we can't include for every architecture and perl variant.
#
# The only prerequisite here is LWP, curl or wget
#
# A compiler is obviously needed too.

use strict;
use lib qw(/usr/local/slimserver/CPAN /usr/share/squeezecenter/CPAN CPAN);
use Config;
use Cwd;
use File::Basename qw(dirname basename);
use File::Copy;
use File::Find;
use File::Path;
use File::Which;

# NOTE: If you change this in a future version of SC, create a new
# versioned directory under vendor/src for all files for that version
my $SOURCE = 'http://svn.slimdevices.com/repos/slim/7.4/trunk/vendor/CPAN/';
my $dlext  = $Config{'dlext'};

# The list of all the packages needed.
my %packages = (
	'Audio::Scan'              => 'Audio-Scan-0.26.tar.gz',
	'AutoXS::Header'           => 'AutoXS-Header-1.02.tar.gz',
	'Class::C3::XS'            => 'Class-C3-XS-0.11.tar.gz',
	'Class::XSAccessor'        => 'Class-XSAccessor-1.03.tar.gz',
	'Class::XSAccessor::Array' => 'Class-XSAccessor-Array-1.04.tar.gz',
	'Compress::Raw::Zlib'      => 'Compress-Raw-Zlib-2.017.tar.gz',
	'DBI'                      => 'DBI-1.608.tar.gz',
	'DBD::mysql'               => 'DBD-mysql-4.011.tar.gz',
	'Digest::SHA1'             => 'Digest-SHA1-2.11.tar.gz',
	'Encode::Detect'           => 'Encode-Detect-1.00.tar.gz',
	'EV'                       => 'EV-3.6.tar.gz',
	'GD'                       => 'GD-2.41.tar.gz',
	'HTML::Parser'             => 'HTML-Parser-3.60.tar.gz',
	'JSON::XS'                 => 'JSON-XS-2.232.tar.gz',
	'Sub::Name'                => 'Sub-Name-0.04.tar.gz',
	'Template'                 => 'Template-Toolkit-2.21.tar.gz',
	'Time::HiRes'              => 'Time-HiRes-1.86.tar.gz',
	'XML::Parser::Expat'       => 'XML-Parser-2.36.tar.gz',
	'YAML::Syck'               => 'YAML-Syck-1.05.tar.gz',
);

# Don't need Class::C3::XS if you're running 5.10
if ( $] > 5.009_004 ) {
	delete $packages{'Class::C3::XS'};
}

# Options for specific packages
my %packageOptions = (
	'Template-Toolkit-2.21' => {

		'Makefile.PL' => join(' ', qw(
			TT_DOCS=n
			TT_SPLASH=n
			TT_THEME=n
			TT_EXAMPLES=n
			TT_EXAMPLES=n
			TT_EXTRAS=n
			TT_QUIET=y
			TT_ACCEPT=y
			TT_DBI=n
			TT_LATEX=n
		)),
	},

	'DBD-mysql-4.011' => {

		'env' => [qw(DBI-1.608/blib/lib: DBI-1.608/blib/arch)],
	},
);

sub main {
	my ($squeezeboxPath, $downloadPath, $perlBinary, @libList, $downloadUsing);

	my $archname = $Config{'archname'};
	my $version  = $Config{'version'};

	print "Welcome to the Slim Devices perl module installer.\n\n";
	print "These packages are needed for Squeezebox Server to function.\n";
	print "You will need a C compiler (gcc), make, and perl installed.\n\n";
	print "You will need development libraries for MySQL. eg: libmysqlclient\n\n";
	print "You will need development libraries for expat. eg: libexpat1-dev\n\n";

	print "*** Ignore any warnings about AppConfig. ***\n\n";

	print "Please enter a perl binary to use (defaults to /usr/bin/perl)\n";
	print "This must be the same perl binary that you ran this program with --> ";
	chomp($perlBinary = <STDIN>);

	$perlBinary ||= '/usr/bin/perl';

	unless (-f $perlBinary && -x $perlBinary) {
		die "Couldn't find a perl binary. Exiting.\n";
	}

	# Where does their Squeezebox Server live? Try to guess.
	if (-f 'slimserver.pl' && -d 'CPAN/arch') {

		$squeezeboxPath = cwd();

	} else {

		print "Please enter the path to your Squeezebox Server directory (ex: /usr/local/slimserver) --> ";
		chomp($squeezeboxPath = <STDIN>);
	}

	$squeezeboxPath ||= '/usr/local/slimserver';

	unless (-d $squeezeboxPath) {
		die "Couldn't find a valid Squeezebox Server path. Exiting.\n";
	}

	# Let the build process use modules installed already:
	$ENV{'PERL5LIB'} = "$squeezeboxPath/CPAN";

	# Tell MakeMaker to always use the default when prompted.
	$ENV{'PERL_MM_USE_DEFAULT'} = 1;

	# This is where the binaries will end up.
	my $cpanDest = "$squeezeboxPath/CPAN/arch/$version/$archname/auto";

	# Where do they want the downloads to go?
	print "Please enter a directory to download files to --> ";
	chomp($downloadPath = <STDIN>);

	# Default to the current directory.
	$downloadPath ||= '.';

	# Remove trailing slash
	$downloadPath =~ s|^(.+?)/$|$1|;

	unless (-d $downloadPath) {
		die "Invalid download path! Exiting.\n";
	}

	chdir($downloadPath) or die "Couldn't change to $downloadPath : $!";

	my $pwd = cwd();

	# What do we want to download with?
	eval { require LWP::Simple };

	# No LWP - try a command line program.
	if ($@) {

		for my $cmd (qw(curl wget)) {

			if ($downloadUsing = which($cmd)) {
				last;
			}
		}

	} else {

		$downloadUsing = 'lwp';
	}

	unless ($downloadUsing) {
		die "Couldn't find any valid downloaders - install LWP, wget or curl.\n";
	} else {
		print "Downloads will use $downloadUsing to fetch tarballs.\n";
	}

	# Only download the packages that were passsed.
	my @packages = ();

	if (scalar @ARGV) {

		for my $package (@ARGV) {

			if (grep { /$package/ } keys %packages) {

				push @packages, $packages{$package};
			}
		}

	} else {

		@packages = sort values %packages;
	}

	# DBI needs to be first.
	if ((grep { /DBI/ } @packages) && (grep { /DBD/ } @packages)) {

		for (my $i = 0; $i < scalar @packages; $i++) {

			if ($packages[$i] =~ /DBD/) {

				my $dbd = $packages[$i];

				$packages[$i] = $packages[$i+1];
				$packages[$i+1] = $dbd;
				last;
			}
		}
	}

	for my $package (@packages) {

		chdir($pwd) or die "Couldn't change to $pwd : $!";

		print "\nDownloading $package to: $pwd\n";

		# Remove any previous version.
		unlink $package;

		if ($downloadUsing eq 'lwp') {

			LWP::Simple::getstore("$SOURCE/$package?view=auto", $package);

		} elsif ($downloadUsing =~ /curl$/) {

			`$downloadUsing --silent -o $package $SOURCE/$package?view=auto`;

		} else {

			`$downloadUsing -q -O $package $SOURCE/$package?view=auto`;
		}

		unless (-r $package) {
			print "Something looks wrong - I couldn't read $pwd/$package, which I just downloaded.\n";
		}

		print "Uncompressing..\n";
		`gzip -d < $package | tar xvf -`;

		unlink $package;

		# Just the directory name.
		my ($packageDir) = ($package =~ /(\S+?)\.tar\.gz/);

		chdir $packageDir or die "Couldn't change to $packageDir : $!";

		#
		my $options = $packageOptions{$packageDir}->{'Makefile.PL'} || '';
		my $env     = '';

		if ($packageOptions{$packageDir}->{'env'}) {
			$env = "PERL5LIB=$pwd/" . join("$pwd/", @{$packageOptions{$packageDir}->{'env'}});
		}

		print "Configuring..\n";
		print "$env $perlBinary Makefile.PL $options\n";
		`$env $perlBinary Makefile.PL $options`;

		unless (-f 'Makefile') {
			die "There was a problem creating Makefile - exiting!\n";
		}

		print "Building..\n";
		`make`;	

		#print "Testing..\n";
		#`make test`;

		my ($lib) = findLibraryInPath('blib');

		unless (defined $lib) {
			die "Couldn't find a valid dynamic library for $package - something is wrong. Exiting!\n";
		}

		# Strip out the build paths
		my $baseLib = $lib;
		$baseLib =~ s|blib/arch/auto/||;

		my $cpanPath = dirname($baseLib);
		my $libName  = basename($baseLib);

		# Create the path for this module to go
		unless (-d "$cpanDest/$cpanPath") {
			mkpath("$cpanDest/$cpanPath") or die "Couldn't create path: $cpanDest/$cpanPath : $!\n";
		}

		copy($lib, "$cpanDest/$cpanPath/$libName") or die "Couldn't copy file to $cpanDest/$cpanPath/$libName : $!\n";

		unless (-f "$cpanDest/$cpanPath/$libName") {
			die "Library for $package has a problem! Exiting..\n";
		}

		print "Library for $package is OK!\n";

		chmod 0755, "$cpanDest/$cpanPath/$libName" or die "Couldn't make $cpanDest/$cpanPath/$libName executable: $!\n";

		push @libList, "$cpanDest/$cpanPath/$libName";
	}

	chdir($pwd) or die "Couldn't change to $pwd : $!";

	print "All done!\n\n";
}

sub findLibraryInPath {
	my $path = shift;

	my @files = ();

	find(sub {

		if ($File::Find::name =~ /\.$dlext$/) {
			push @files, $File::Find::name;
		}

	}, $path);

	return @files;
}

main();
