# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# runtimes/uv.pm: the `uv` runtime -- uv's package cache (safe verb uv cache prune, purge verb uv cache clean).
# A core runtime module (interface: CachePrune/Runtime.pm POD), loaded by cache-prune.pl in the
# CachePrune::Runtime::CORE_ORDER slot. perl-base only.
package CachePrune::Runtime::uv;
use strict;
use warnings;
use CachePrune::Core ();
use CachePrune::Adapters ();
use CachePrune::Runtime ();

# cache_dir: asked of uv itself, never hardcoded; a non-absolute answer is unresolvable.
sub cache_dir {
	my ($dir, $rc) = CachePrune::Core::cmd_capture('uv', 'cache', 'dir');
	return (1) if $rc != 0;
	return (2) unless $dir =~ m{\A/};
	return (0, $dir);
}

CachePrune::Runtime::register_runtime({
	name => 'uv',
	detect => sub { CachePrune::Core::have_cmd('uv') },
	absent => sub { 'no uv on host' },
	cache_dir => \&cache_dir,
	size => \&CachePrune::Adapters::generic_size,
	prune => sub { CachePrune::Core::cmd_run('uv', 'cache', 'prune') == 0 },
	# The destructive purge: clears the whole cache, forcing a re-download on next use.
	purge => sub { CachePrune::Core::cmd_run('uv', 'cache', 'clean') == 0 },
});

1;
