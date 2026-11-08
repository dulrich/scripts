# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# runtimes/bun.pm: the `bun` runtime -- bun's install cache (purge verb only).
# A core runtime module (interface: CachePrune/Runtime.pm POD), loaded by cache-prune.pl in the
# CachePrune::Runtime::CORE_ORDER slot. perl-base only.
package CachePrune::Runtime::bun;
use strict;
use warnings;
use CachePrune::Core ();
use CachePrune::Adapters ();
use CachePrune::Runtime ();

sub cache_dir {
	my $prefix = (defined $ENV{BUN_INSTALL} && length $ENV{BUN_INSTALL}) ? $ENV{BUN_INSTALL} : "$ENV{HOME}/.bun";
	return (0, "$prefix/install/cache");
}

# purge: `bun pm cache rm` fails outside a package directory, so it runs from a scratch
# directory holding a minimal package.json. If it still fails it is a verb failure -- never a
# fallback to deleting the cache path ourselves.
sub purge {
	my ($out, $rc) = CachePrune::Core::cmd_capture('mktemp', '-d');
	return 0 if $rc != 0 || !length $out;
	my $scratch = $out;
	my $ok = 0;
	if (open(my $fh, '>', "$scratch/package.json")) {
		print $fh "{}\n";
		close $fh;
		$ok = CachePrune::Core::cmd_run({ dir => $scratch }, 'bun', 'pm', 'cache', 'rm') == 0;
	}
	CachePrune::Core::cmd_run('rm', '-rf', '--', $scratch);
	return $ok;
}

CachePrune::Runtime::register_runtime({
	name => 'bun',
	detect => sub { CachePrune::Core::have_cmd('bun') },
	absent => sub { 'no bun on host' },
	cache_dir => \&cache_dir,
	size => \&CachePrune::Adapters::generic_size,
	purge => \&purge,
	help => { core_env_lead => q{  BUN_INSTALL   overrides bun's install prefix (cache under install/cache)} },
});

1;
