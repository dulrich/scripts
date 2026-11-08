# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# runtimes/pip.pm: the `pip` runtime -- pip's http/wheel cache (purge verb only).
# A core runtime module (interface: CachePrune/Runtime.pm POD), loaded by cache-prune.pl in the
# CachePrune::Runtime::CORE_ORDER slot. perl-base only.
package CachePrune::Runtime::pip;
use strict;
use warnings;
use CachePrune::Core ();
use CachePrune::Adapters ();
use CachePrune::Runtime ();

sub cache_dir {
	my ($dir, $rc) = CachePrune::Core::cmd_capture('pip', 'cache', 'dir');
	return (1) if $rc != 0;
	return (2) unless $dir =~ m{\A/};
	return (0, $dir);
}

CachePrune::Runtime::register_runtime({
	name => 'pip',
	detect => sub { CachePrune::Core::have_cmd('pip') },
	absent => sub { 'no pip on host' },
	cache_dir => \&cache_dir,
	size => \&CachePrune::Adapters::generic_size,
	purge => sub { CachePrune::Core::cmd_run('pip', 'cache', 'purge') == 0 },
});

1;
