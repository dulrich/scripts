# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# runtimes/cargo.pm: the `cargo` runtime -- cargo's unpacked registry sources (registry/src purge only).
# A core runtime module (interface: CachePrune/Runtime.pm POD), loaded by cache-prune.pl in the
# CachePrune::Runtime::CORE_ORDER slot. perl-base only.
package CachePrune::Runtime::cargo;
use strict;
use warnings;
use CachePrune::Core ();
use CachePrune::Adapters ();
use CachePrune::Runtime ();

use Fcntl qw(O_RDWR O_CREAT LOCK_EX LOCK_NB);
use CachePrune::Measurement ();
use CachePrune::Actions ();

sub home { return (defined $ENV{CARGO_HOME} && length $ENV{CARGO_HOME}) ? $ENV{CARGO_HOME} : "$ENV{HOME}/.cargo"; }

# size: total is the whole registry/ (cache/, index/, src/); reclaimable is registry/src
# alone -- the only part the purge verb removes.
sub size {
	my (undef, $dir) = @_;
	my ($total) = CachePrune::Adapters::dir_census_bytes($dir);
	my ($src) = CachePrune::Adapters::dir_census_bytes("$dir/src");
	return CachePrune::Measurement::probe_available($total, $src, 'census');
}

# purge: removes only the children of $CARGO_HOME/registry/src (cargo re-extracts them from
# registry/cache offline); cache/, index/ and git/ are never touched. Guarded: no symlinked
# registry/src component, and both package-cache locks must be free (opened read-write, which
# creates them when absent; never removed). Every guarded skip warns and returns true.
sub purge {
	my $home = home();
	my $src = "$home/registry/src";
	return 1 unless -e $src || -l $src;
	my $real_home = CachePrune::Actions::realpath_e($home);
	my $real_src = CachePrune::Actions::realpath_e($src);
	if (!defined $real_home || -l "$home/registry" || -l $src
		|| !defined $real_src || $real_src ne "$real_home/registry/src") {
		CachePrune::Core::warn_msg("cargo: skipped $src (guard: symlinked or escapes CARGO_HOME)");
		return 1;
	}
	my @fhs;
	for my $lock ("$home/.package-cache", "$home/.package-cache-mutate") {
		my $fh;
		if (!sysopen($fh, $lock, O_RDWR | O_CREAT) || !flock($fh, LOCK_EX | LOCK_NB)) {
			close $_ for @fhs;
			CachePrune::Core::warn_msg("cargo: skipped $src (guard: a cargo package-cache lock is held)");
			return 1;
		}
		push @fhs, $fh;
	}
	my $ok = 1;
	if (opendir(my $dh, $src)) {
		for my $n (grep { $_ ne '.' && $_ ne '..' } readdir $dh) {
			my ($rc) = CachePrune::Actions::guarded_remove("$real_home/registry/src", "$src/$n");
			next if $rc == 0;
			$ok = 0;
			CachePrune::Core::warn_msg("cargo: failed to remove $src/$n") if $rc == 3;
		}
		closedir $dh;
	}
	close $_ for @fhs;
	return $ok;
}

CachePrune::Runtime::register_runtime({
	name => 'cargo',
	detect => sub { CachePrune::Core::have_cmd('cargo') },
	absent => sub { 'no cargo on host' },
	cache_dir => sub { (0, home() . '/registry') },
	size => \&size,
	# No prune hook, by decision: cargo's only verb is the registry/src purge.
	purge => \&purge,
	help => {
		core_env_lead => q{  CARGO_HOME    overrides cargo's home (the purge verb removes only the
                children of registry/src, the unpacked crate sources;
                registry/cache, registry/index and git/ are kept, and
                cargo re-extracts src from registry/cache offline)},
		core_purge_caveat => q{cargo clears registry/src children only},
	},
});

1;
