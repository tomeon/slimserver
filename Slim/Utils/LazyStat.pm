package Slim::Utils::LazyStat;

=head1 NAME

Slim::Utils::LazyStat - lazy stat objects

=head1 SYNOPSIS

	my $stat = Slim::Utils::LazyStat->stat('/path/to/file');
	print $stat->[7]; # size of '/path/to/file'

	my $lstat = Slim::Utils::LazyStat->lstat('/path/to/possible/link');
	print $lstat->[2]; # mode of '/path/to/possible/link'

=head1 DESCRIPTION

C<Slim::Utils::LazyStat> implements lazy, caching versions of the L<< C<stat>
>> and L<< C<lstat> >> builtin functions.  This means that you can (a)
instantiate a C<Slim::Utils::LazyStat> without triggering a stat syscall, and
(b) (re-)access the stat results on-demand without relying on the global state
that's in play when using the special C<_> filehandle.

An illustration:

	$ echo aaaaaaaa > foo
	$ echo bbbb > bar
	$ perl -wle 'sub bar { print((stat "./bar")[7]) } sub foo { print((stat "./foo")[7]); bar(); print((stat _)[7]) } foo()'
	9
	5
	5

On the other hand:

	$ echo aaaaaaaa > foo
	$ echo bbbb > bar
	$ perl -MSlim::Utils::LazyStat -wle 'sub bar { print((stat "./bar")[7]) } sub foo { print((my $stat = Slim::Utils::LazyStat->stat("./foo"))->[7]); bar(); print $stat->[7] } foo()'
	9
	5
	9

=head1 METHODS

=over 2

=item stat

Instantiate a C<Slim::Utils::LazyStat> object.  Uses the L<< C<stat> >> builtin
under the hood.

=item lstat

Instantiate a C<Slim::Utils::LazyStat> object.  Uses the L<< C<lstat> >>
builtin under the hood.

=back

=cut

use strict;
use warnings;

use overload q(@{}) => sub { $_[0]->() };

sub stat {
		my ( $class, $path ) = @_;
		my $stat;
		return bless sub {
			return $stat //= [CORE::stat($path)];
		}, $class;
};

sub lstat {
		my ( $class, $path ) = @_;
		my $lstat;
		return bless sub {
			return $lstat //= [CORE::lstat($path)];
		}, $class;
}

{
		no warnings qw(once);
		*new = \&stat;
}

1;
