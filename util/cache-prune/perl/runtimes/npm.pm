# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# runtimes/npm.pm: the `npm` runtime -- npm's package cache (safe verb npm cache verify, purge verb npm cache clean --force).
# A core runtime module (interface: CachePrune/Runtime.pm POD), loaded by cache-prune.pl in the
# CachePrune::Runtime::CORE_ORDER slot. perl-base only.
package CachePrune::Runtime::npm;
use strict;
use warnings;
use CachePrune::Core ();
use CachePrune::Adapters ();
use CachePrune::Runtime ();

# cache_dir: npm is often nvm-managed, so its cache location is PATH-dependent and always
# asked for. `npm config get cache` can print "undefined": any non-absolute answer is an
# unresolvable skip (2), not a failure (1, reserved for npm itself erroring out).
sub cache_dir {
	my ($dir, $rc) = CachePrune::Core::cmd_capture('npm', 'config', 'get', 'cache');
	return (1) if $rc != 0;
	return (2) unless $dir =~ m{\A/};
	return (0, $dir);
}

CachePrune::Runtime::register_runtime({
	name => 'npm',
	detect => sub { CachePrune::Core::have_cmd('npm') },
	absent => sub { 'no npm on host' },
	cache_dir => \&cache_dir,
	size => \&CachePrune::Adapters::generic_size,
	prune => sub { CachePrune::Core::cmd_run('npm', 'cache', 'verify') == 0 },
	purge => sub { CachePrune::Core::cmd_run('npm', 'cache', 'clean', '--force') == 0 },
});

1;
