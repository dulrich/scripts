# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# CachePrune::Actions: the election rules that decide which of a runtime's verbs run in the
# current mode, verb execution, and the shared guarded-removal / discovery helpers every module
# that deletes files directly must use. Nothing here measures anything: the before/after probes
# bracketing run_elected_verbs belong to CachePrune::Main. perl-base only.
package CachePrune::Actions;
use strict;
use warnings;
use Cwd ();
use CachePrune::Core ();

### election ##################################################################

# tier_elected($kind, $prompt, $interactive_only_note) -> bool, from $MODE / $INCLUDE_PURGE:
#   safe:  report never; yes always; interactive confirms
#   purge: report never; yes only with --include-purge; interactive confirms only with it
#   optin: as purge, but interactive confirms unconditionally
#   item:  per-item confirm: never under report or yes; interactive confirms only with
#          --include-purge
# A non-empty $interactive_only_note marks interactive-only data: under --yes the note is
# printed on stdout and nothing is elected, whatever --include-purge says.
sub tier_elected {
	my ($kind, $prompt, $only) = @_;
	my $mode = $CachePrune::Core::MODE;
	if ($mode eq 'yes') {
		if (defined $only && length $only) { print "$only\n"; return 0; }
		return 1 if $kind eq 'safe';
		return $CachePrune::Core::INCLUDE_PURGE ? 1 : 0 if $kind eq 'purge' || $kind eq 'optin';
		return 0;
	}
	if ($mode eq 'interactive') {
		return CachePrune::Core::confirm($prompt) ? 1 : 0 if $kind eq 'safe' || $kind eq 'optin';
		if ($kind eq 'purge' || $kind eq 'item') {
			return 0 unless $CachePrune::Core::INCLUDE_PURGE;
			return CachePrune::Core::confirm($prompt) ? 1 : 0;
		}
	}
	return 0;
}

# safe_elected($rt): the runtime has a safe verb (prune) and the mode elects it.
sub safe_elected {
	my ($rt) = @_;
	return 0 unless $rt->{prune};
	return tier_elected('safe', "Prune $rt->{name} cache?");
}

# purge_elected($rt): the runtime has a purge verb and the mode elects it. A runtime that also
# has a safe verb (uv/npm) is gated on --include-purge even interactively (kind purge); a
# purge-only one (pip/bun/cargo) is confirmed unconditionally interactively (kind optin).
sub purge_elected {
	my ($rt) = @_;
	return 0 unless $rt->{purge};
	my $kind = $rt->{prune} ? 'purge' : 'optin';
	my $prompt = "Purge $rt->{name} cache? (opt-in, destructive)";
	if ($CachePrune::Core::MODE eq 'interactive' && $rt->{purge_prompt}) {
		$prompt = $rt->{purge_prompt}->($rt);
	}
	return tier_elected($kind, $prompt, $rt->{interactive_only});
}

### execution #################################################################

# run_verb($rt, $hook): run one verb; a false return warns "<name>: prune failed" and sets
# $FAILED; success prints "<name>: prune complete." (the wording is pinned for both tiers).
sub run_verb {
	my ($rt, $hook) = @_;
	if (!$hook->($rt)) {
		CachePrune::Core::warn_msg("$rt->{name}: prune failed");
		$CachePrune::Core::FAILED = 1;
		return 0;
	}
	print "$rt->{name}: prune complete.\n";
	return 1;
}

# run_elected_verbs($rt) -> ($acted, $verb_failed). Under --yes a purge election supersedes
# the safe verb (it never runs too); interactively each elected verb runs, safe first, and a
# failed safe verb skips the purge election.
sub run_elected_verbs {
	my ($rt) = @_;
	my ($acted, $failed) = (0, 0);
	if ($CachePrune::Core::MODE eq 'yes') {
		if (purge_elected($rt)) {
			$acted = 1;
			$failed = 1 unless run_verb($rt, $rt->{purge});
		} elsif (safe_elected($rt)) {
			$acted = 1;
			$failed = 1 unless run_verb($rt, $rt->{prune});
		}
	} else {
		if (safe_elected($rt)) {
			$acted = 1;
			$failed = 1 unless run_verb($rt, $rt->{prune});
		}
		if (!$failed && purge_elected($rt)) {
			$acted = 1;
			$failed = 1 unless run_verb($rt, $rt->{purge});
		}
	}
	return ($acted, $failed);
}

### guarded deletion and shared path helpers ##################################

# realpath_e($path): realpath of an existing path (realpath -e), else undef.
sub realpath_e {
	my ($p) = @_;
	return undef unless defined $p && length $p && -e $p;
	return Cwd::realpath($p);
}

# guarded_remove($root_real, $path) -> (code, candidate). The parent of $path is resolved and
# the basename re-appended, so a symlinked leaf is removed as a link, never followed.
#   0 removed; 1 parent unresolvable or candidate missing; 2 candidate not strictly inside
#   $root_real (the root itself included); 3 `rm -rf --one-file-system` failed.
sub guarded_remove {
	my ($root, $path) = @_;
	my ($parent, $base) = $path =~ m{\A(.*)/([^/]*)\z} ? ($1, $2) : ('', $path);
	my $preal = realpath_e(length $parent ? $parent : '/');
	return (1, '') unless defined $preal && -d $preal;
	my $cand = ($preal eq '/' ? '' : $preal) . "/$base";
	return (1, $cand) unless -e $cand || -l $cand;
	return (2, $cand) unless index($cand, "$root/") == 0 && length $cand > length("$root/");
	my $rc = CachePrune::Core::cmd_run('rm', '-rf', '--one-file-system', '--', $cand);
	return ($rc == 0 ? 0 : 3, $cand);
}

# path_contained($path, $expected_real): $path is not itself a symlink and its realpath equals
# $expected_real (no symlinked component on the way).
sub path_contained {
	my ($path, $expected) = @_;
	return 0 if -l $path;
	my $real = realpath_e($path);
	return (defined $real && $real eq $expected) ? 1 : 0;
}

# path_on_noatime_mount($path, $mounts_file): the longest-prefix mount holding $path carries
# noatime. $mounts_file replaces /proc/self/mounts when non-empty (test seam); an unreadable
# table or unresolvable path reads as not noatime. "\040" in a mount point is a space.
sub path_on_noatime_mount {
	my ($path, $src) = @_;
	$src = '/proc/self/mounts' unless defined $src && length $src;
	my $real = realpath_e($path);
	return 0 unless defined $real;
	open(my $fh, '<', $src) or return 0;
	my ($best, $opts) = ('', '');
	while (my $line = <$fh>) {
		my (undef, $mp, undef, $mo) = split ' ', $line;
		next unless defined $mp;
		$mp =~ s/\\040/ /g;
		if (($mp eq '/' || $real eq $mp || index($real, "$mp/") == 0) && length $mp >= length $best) {
			($best, $opts) = ($mp, $mo // '');
		}
	}
	close $fh;
	return index(",$opts,", ',noatime,') >= 0 ? 1 : 0;
}

# path_git_tracked($dir): $dir is inside a git work tree and some path under it is tracked.
sub path_git_tracked {
	my ($dir) = @_;
	my ($in, $rc) = CachePrune::Core::cmd_capture({ stderr => 'null' }, 'git', '-C', $dir,
		'rev-parse', '--is-inside-work-tree');
	return 0 unless $rc == 0;
	my ($ls) = CachePrune::Core::cmd_capture({ stderr => 'null' }, 'git', '-C', $dir, 'ls-files', '--', '.');
	return length($ls // '') ? 1 : 0;
}

# outermost_marker_dirs($root, $validator, $match) -> sorted list of the outermost directories
# under $root holding a regular file (never a symlink) for which $match->($path, $basename) is
# true. The walk never follows symlinks and skips anything named .git or node_modules.
# $validator (coderef or undef) is called with each marker path before deduplication; a marker
# it rejects is dropped, so an invalid ancestor marker never hides a valid nested one.
sub outermost_marker_dirs {
	my ($root, $validator, $match) = @_;
	my %dirs;
	my @stack = ($root);
	while (@stack) {
		my $d = pop @stack;
		opendir(my $dh, $d) or next;
		my @names = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
		closedir $dh;
		for my $n (@names) {
			next if $n eq '.git' || $n eq 'node_modules';
			my $p = "$d/$n";
			lstat $p or next;
			if (-d _) { push @stack, $p; next; }
			next unless -f _;
			next unless $match->($p, $n);
			next if $validator && !$validator->($p);
			$dirs{"$d/"} = 1;
		}
	}
	my (@out, $prev);
	for my $d (sort keys %dirs) {
		next if defined $prev && index($d, $prev) == 0;
		$prev = $d;
		(my $x = $d) =~ s{/\z}{};
		push @out, $x;
	}
	return @out;
}

# env_days($value, $default): $value when it is all digits, else $default.
sub env_days {
	my ($v, $default) = @_;
	return (defined $v && $v =~ /\A[0-9]+\z/) ? $v : $default;
}

1;
