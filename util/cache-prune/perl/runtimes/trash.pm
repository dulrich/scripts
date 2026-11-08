# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# runtimes/trash.pm: the `trash` runtime -- the user's home trash (purge verb only,
# interactive-only: user-deleted data, never emptied under --yes). A core runtime module
# (interface: CachePrune/Runtime.pm POD), loaded in the CachePrune::Runtime::CORE_ORDER slot.
# The port of runtimes/trash.sh. perl-base only.
package CachePrune::Runtime::trash;
use strict;
use warnings;
use CachePrune::Core ();
use CachePrune::Measurement ();
use CachePrune::Adapters ();
use CachePrune::Runtime ();

sub _env { my $v = $ENV{ $_[0] }; return (defined $v && length $v) ? $v : undef; }

# trash_dir: CACHE_PRUNE_TRASH_DIR, else ${XDG_DATA_HOME:-$HOME/.local/share}/Trash.
sub trash_dir {
	return _env('CACHE_PRUNE_TRASH_DIR') // ((_env('XDG_DATA_HOME') // (($ENV{HOME} // '') . '/.local/share')) . '/Trash');
}

sub gio { return _env('CACHE_PRUNE_GIO') // 'gio'; }

sub detect { return (CachePrune::Core::have_cmd(gio()) && -d trash_dir()) ? 1 : 0; }

sub absent {
	my $g = gio();
	if (!CachePrune::Core::have_cmd($g)) { (my $b = $g) =~ s{.*/}{}s; return "no $b on host"; }
	return 'trash dir ' . trash_dir() . ' absent';
}

# trash_bytes: files/ + info/ (+ expunged/ when present); absent subdirs count as zero.
sub trash_bytes {
	my $dir = trash_dir();
	my $total = 0;
	for my $sub (qw(files info expunged)) {
		next unless -e "$dir/$sub";
		$total += CachePrune::Adapters::path_du_bytes("$dir/$sub");
	}
	return $total;
}

# size: everything in the trash is purge-tier reclaimable, so reclaimable == total.
sub size {
	return CachePrune::Measurement::probe_unavailable() unless detect();
	my $b = trash_bytes();
	return CachePrune::Measurement::probe_available($b, $b, 'trash');
}

# detail: item count in files/ plus the per-mount note.
sub detail {
	my $dir = trash_dir();
	my $count = 0;
	if (opendir(my $dh, "$dir/files")) {
		$count = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
		closedir $dh;
	}
	printf "trash: %d items in files/ -- purge tier, interactive confirm only\n", $count;
	print "note: gio trash --empty also empties per-mount .Trash-<uid> dirs, which are not sized here.\n";
}

sub purge_prompt {
	my $b = trash_bytes();
	return sprintf('Empty trash (%s, %d bytes of user-deleted data, not a cache)? (destructive, via gio trash --empty)',
		CachePrune::Measurement::human_bytes($b), $b);
}

# purge: delegates to `gio trash --empty` (never a direct rm).
sub purge { return CachePrune::Core::cmd_run(gio(), 'trash', '--empty') == 0; }

CachePrune::Runtime::register_runtime({
	name => 'trash',
	detect => \&detect,
	absent => \&absent,
	size => \&size,
	purge => \&purge,
	purge_prompt => \&purge_prompt,
	detail => \&detail,
	interactive_only => 'skipped: trash needs an interactive confirm (user-deleted data; never emptied under --yes)',
	help => {
		core_runtimes => ['The trash runtime reports the user\'s home trash (files/, info/ and
expunged/ under ${XDG_DATA_HOME:-$HOME/.local/share}/Trash); detected only
when gio is installed and that dir exists. Purge tier, interactive-only:
it is user-deleted data, not a rebuildable cache, so it is NEVER emptied
under --yes (not even with --include-purge) -- only by one interactive
confirm, via `gio trash --empty` (never a direct rm). gio also empties
per-mount .Trash-$UID dirs, which are not sized here.
'],
		core_env => ['  CACHE_PRUNE_TRASH_DIR
                overrides the trash dir the trash runtime sizes (default
                ${XDG_DATA_HOME:-$HOME/.local/share}/Trash)', '  CACHE_PRUNE_GIO
                overrides the gio command the trash runtime detects and
                runs (default gio)'],
	},
});

1;
