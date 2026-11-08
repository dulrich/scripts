# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# CachePrune::Main: the command-line surface, the per-runtime lifecycle (detect/resolve,
# measure/report, elect/run, measure/report the outcome) and the Total block. Every runtime is
# a registered module (CachePrune::Runtime); nothing here names one. perl-base only.
package CachePrune::Main;
use strict;
use warnings;
use CachePrune::Core ();
use CachePrune::Measurement qw(probe_is_valid probe_is_available probe_fields probe_compare
	human_bytes human_bytes_signed);
use CachePrune::Actions ();
use CachePrune::Runtime ();

# Totals, reset by main(). Reclaimable is kept per tier, never conflated; OVERLAP counts the
# safe bytes of split-tier runtimes that are also inside their purge figure.
our $TOTAL_BYTES = 0;
our $SAFE_RECLAIMABLE_BYTES = 0;
our $PURGE_RECLAIMABLE_BYTES = 0;
our $OVERLAP_RECLAIMABLE_BYTES = 0;
our $DELTA_BYTES = 0;

# The name usage errors print (bash: $0); a future shim sets CACHE_PRUNE_SHIM to its own path.
sub prog_name { return (defined $ENV{CACHE_PRUNE_SHIM} && length $ENV{CACHE_PRUNE_SHIM}) ? $ENV{CACHE_PRUNE_SHIM} : $0; }

sub reset_totals {
	$TOTAL_BYTES = $SAFE_RECLAIMABLE_BYTES = $PURGE_RECLAIMABLE_BYTES = 0;
	$OVERLAP_RECLAIMABLE_BYTES = $DELTA_BYTES = 0;
}

### usage #####################################################################

sub _frag { print "$_\n" for @{ $CachePrune::Runtime::HELP{ $_[0] } }; }

sub usage {
	print <<'TXT';
usage: cache-prune [--report | --yes [--include-purge]]
                    [--docker-until <window>] [-h|--help]

Reports (and, outside --report, optionally prunes) rebuildable
language-runtime caches (uv, npm, docker, pip, bun, cargo) plus the
home trash (trash) for the invoking user. Refuses to run as root.

Modes:
  (default)              interactive; per-runtime confirm (default: No)
  --report               report cache sizes only; never prompts, never mutates
  --yes                  auto-confirm the safe verb for uv, npm, docker;
                         pip, bun and cargo have no safe verb and are
                         skipped entirely, never prompted; trash is never
                         emptied under --yes
  --yes --include-purge  purges pip, bun and cargo (their only verb;
                         cargo clears registry/src children only); for uv,
                         npm and docker this instead runs their purge verb in
                         place of their safe verb, not in addition to it; trash
                         is still skipped (interactive confirm only)

uv and npm each carry two verbs: a conservative safe verb (uv cache prune,
npm cache verify) that frees little by design, and a destructive purge
verb (uv cache clean, npm cache clean --force) that clears the whole
cache and forces a re-download on next use -- the cache-only bytes this
tool reports as reclaimable are mostly only reachable via the purge verb.
docker carries two verbs too: its safe verb (docker builder prune) frees
the figure reported as reclaimable; its purge verb (docker builder
prune -a) clears the whole unused build cache, up to its reported total,
forcing cold rebuilds, and is never age-filtered.
pip and bun have only the destructive purge verb. Interactively, each
destructive purge gets its own separate confirm: pip/bun are offered
theirs unconditionally (it is their only verb), uv/npm/docker
are offered theirs
only when --include-purge was also passed -- without it, plain interactive
use never risks their caches.

Docker image/container residue (after the build-cache verb(s), from a fresh
classification; never in --report; named volumes are reported, never removed):
  superseded images      an older tag of a repository a live compose
                         service or Dockerfile base uses -- safe tier:
                         removed by --yes (docker rmi <repo:tag>), one
                         confirm interactively
  stale containers       created/exited containers of no current compose
                         service -- purge tier: removed (docker rm) only by
                         --yes --include-purge, or one confirm interactively
                         with --include-purge
  anonymous volumes      dangling volumes labelled com.docker.volume.anonymous
                         that were already dangling before this run's
                         removals -- purge tier, same rule as stale
                         containers (docker volume rm <name>)
  unreferenced images    images nothing live references -- never removed
                         non-interactively; interactive --include-purge
                         offers one confirm per image
  Order: stale containers, anonymous volumes, superseded, unreferenced. Never -f, never prune.
  A per-item failure (e.g. an image still in use) is a warning; the rest
  continue. The step prints its own images/containers/volumes footprint change.

Options:
  --docker-until <window>  narrow the docker safe builder prune (never the
                           purge verb, which is always unfiltered) to records at
                           least that old (default: no filter -- the safe
                           prune targets the full build cache docker
                           itself reports as reclaimable). Opt-in because
                           a window leaves recent build cache in place,
                           while the default clears all of it.
  -h, --help               show this help and exit

TXT
	_frag('runtimes');
	_frag('core_runtimes');
	print <<'TXT';
Notes:
  Reclaimable is reported per tier, never as one combined figure: docker's
  safe-tier figure is an upper bound (Docker's own "not pinned by an active
  build" definition), not a guarantee of what a prune will actually free;
  uv/npm/pip/bun's purge-tier figure is what a full clean would free, and is
  never printed against their safe verb -- uv/npm's safe verb frees an
  unpredictable amount by design (no dry run exists for it) and is reported
  as such rather than with a number attached to it.

  Every action (outside --report) measures the affected cache immediately
  before and after and reports the observed footprint change -- a
  measurement, not an exact attribution: docker's own accounting has been
  measured to disagree with real disk freed by about 1%, and a concurrent
  cache write can make the delta negative. A run that frees nothing reports
  0B explicitly rather than falling back to the estimate.

Honoured environment:
TXT
	_frag('core_env_lead');
	print <<'TXT';
  CACHE_PRUNE_REPO_ROOT
                overrides the root docker residue classification searches
                for compose files (default: unset, which skips the compose
                search; a fleet module may supply a default)
  CACHE_PRUNE_COMPOSE_PROJECT_DIRS
                newline-separated <file>=<dir> pairs, both relative to that
                root: each listed compose file is resolved with
                --project-directory <root>/<dir> (default: none pinned
                unless a fleet module sets one)
TXT
	_frag('env');
	_frag('core_env');
}

### guards ####################################################################

# usage_error: exit status 1, as the bash CLI really exits (its die fails under set -e before
# its `return 2` is reached; only a rejected --docker-until window exits 2 there).
sub usage_error {
	CachePrune::Core::die_msg('usage: ' . prog_name()
		. ' [--report|--yes] [--include-purge] [--docker-until <window>] [-h|--help]');
	return 1;
}

# set_docker_until($window) -> 1 accepted, 0 rejected (message printed, window untouched).
sub set_docker_until {
	my ($w) = @_;
	if (!defined CachePrune::Core::docker_window_seconds($w)) {
		CachePrune::Core::die_msg("invalid --docker-until window: '$w'",
			'(expected <number><s|m|h|d|w>, e.g. 168h)');
		return 0;
	}
	$CachePrune::Core::DOCKER_UNTIL = $w;
	return 1;
}

# require_not_root($euid): true when allowed; the EUID is a parameter so tests can pass 0.
sub require_not_root {
	my ($euid) = @_;
	$euid = $> unless defined $euid;
	return 1 if $euid != 0;
	CachePrune::Core::die_msg('Refusing to run as root: uv/npm/pip/bun/cargo caches live under',
		"the invoking user's account, not root's -- running this as root",
		"would report and prune root's own empty caches. Re-run as your", 'normal user.');
	return 0;
}

sub require_tty {
	return 1 if -t STDIN && -t STDOUT;
	CachePrune::Core::die_msg('An interactive terminal is required for this mode. Use --report',
		'or --yes for non-interactive use.');
	return 0;
}

### lifecycle #################################################################

sub absent_reason {
	my ($rt) = @_;
	my $r = $rt->{absent} ? $rt->{absent}->($rt) : '';
	$r = '' unless defined $r;
	$r =~ s/\n+\z//;
	return length $r ? $r : 'not detected';
}

# resolve_cache_dir($rt) -> (0, dir) continue; (1) hard failure; (2) graceful skip.
sub resolve_cache_dir {
	my ($rt) = @_;
	return (0, '') unless $rt->{cache_dir};
	my ($st, $dir) = $rt->{cache_dir}->($rt);
	$st //= 1;
	if ($st == 2) { print "skip: $rt->{name} cache location unresolved\n"; return (2); }
	if ($st != 0) {
		CachePrune::Core::warn_msg("$rt->{name}: failed to resolve cache location");
		$CachePrune::Core::FAILED = 1;
		return (1);
	}
	return (0, $dir // '');
}

# measure_runtime($rt, $dir) -> (0, record) | (1) probe failed | (2) malformed.
sub measure_runtime {
	my ($rt, $dir) = @_;
	my $r = $rt->{size}->($rt, $dir);
	return (1) unless defined $r;
	return (2) unless length $r && probe_is_valid($r);
	return (0, $r);
}

sub report_measurement {
	my ($rt, $total, $recl) = @_;
	my $name = $rt->{name};
	printf "%s cache size: %s total (%d bytes)\n", $name, human_bytes($total), $total;
	$TOTAL_BYTES += $total;
	if ($rt->{prune} && $rt->{purge} && $rt->{safe_reclaimable}) {
		my $safe = $rt->{safe_reclaimable}->($rt);
		$safe = 0 unless defined $safe && $safe =~ /\A[0-9]+\z/;
		$safe = $recl if $safe > $recl;
		printf "%s reclaimable via the safe verb (%s, %d bytes)\n", $name, human_bytes($safe), $safe;
		printf "%s reclaimable via the purge verb (%s, %d bytes) -- requires --include-purge; includes the safe-verb %s above (a superset, not additive)\n",
			$name, human_bytes($recl), $recl, human_bytes($safe);
		$SAFE_RECLAIMABLE_BYTES += $safe;
		$PURGE_RECLAIMABLE_BYTES += $recl;
		$OVERLAP_RECLAIMABLE_BYTES += $safe;
	} elsif ($rt->{purge} && !(defined $rt->{purge_unpredicted_note} && length $rt->{purge_unpredicted_note})) {
		my $gate = 'requires --include-purge';
		$gate = 'emptied only after an interactive confirm, never under --yes'
			if defined $rt->{interactive_only} && length $rt->{interactive_only};
		printf "%s reclaimable via the purge verb (%s, %d bytes) -- %s\n", $name, human_bytes($recl), $recl, $gate;
		$PURGE_RECLAIMABLE_BYTES += $recl;
		if ($rt->{prune}) {
			print "note: ${name}'s safe verb cannot be predicted (no dry run exists) -- it is not represented by any reclaimable figure here.\n";
		}
	} elsif ($rt->{prune}) {
		printf "%s reclaimable via the safe verb (%s, %d bytes)\n", $name, human_bytes($recl), $recl;
		$SAFE_RECLAIMABLE_BYTES += $recl;
		print "$rt->{safe_estimate_note}\n" if defined $rt->{safe_estimate_note} && length $rt->{safe_estimate_note};
		print "$rt->{purge_unpredicted_note}\n"
			if $rt->{purge} && defined $rt->{purge_unpredicted_note} && length $rt->{purge_unpredicted_note};
	}
}

# report_delta($rt, $dir, $before, $verb_failed): one post-action probe spanning every verb.
sub report_delta {
	my ($rt, $dir, $before, $verb_failed) = @_;
	my $name = $rt->{name};
	my ($st, $after) = measure_runtime($rt, $dir);
	$after = '' if $st != 0;
	my $verdict = probe_compare($name, $before, $after);
	my ($vs, $rest) = split / /, $verdict, 2;
	if ($vs ne 'available') {
		print "$name: observed footprint change: unavailable ($rest)\n";
		return;
	}
	my $delta = $rest;
	$DELTA_BYTES += $delta;
	my $note = '';
	if ($verb_failed) {
		$note = ' -- partial result: the action above reported failure';
	} elsif ($delta < 0) {
		$note = ' -- negative: the cache grew between probes (a concurrent write can do this)';
	}
	printf "%s: observed footprint change: %s (%d bytes)%s\n", $name, human_bytes_signed($delta), $delta, $note;
}

# process_runtime($rt) -> true unless the runtime failed.
sub process_runtime {
	my ($rt) = @_;
	my $name = $rt->{name};
	CachePrune::Core::section($name);
	if (!$rt->{detect}->($rt)) {
		print "skip: $name: " . absent_reason($rt) . "\n";
		return 1;
	}
	my ($rst, $dir) = resolve_cache_dir($rt);
	return 1 if $rst == 2;
	return 0 if $rst != 0;

	my ($mst, $before) = measure_runtime($rt, $dir);
	if ($mst == 1) {
		CachePrune::Core::warn_msg("$name: failed to determine cache size");
		$CachePrune::Core::FAILED = 1;
		return 0;
	} elsif ($mst != 0) {
		CachePrune::Core::warn_msg("$name: cache size probe returned a malformed result");
		$CachePrune::Core::FAILED = 1;
		return 0;
	}

	if (!probe_is_available($before)) {
		print "$name cache size: unavailable\n";
		print "skip: $name size unavailable, skipping action for safety.\n";
		return 1;
	}
	my (undef, $bt, $br) = probe_fields($before);
	report_measurement($rt, $bt, $br);
	$rt->{detail}->($rt) if $rt->{detail};

	return 1 if $CachePrune::Core::MODE eq 'report';

	my ($acted, $vfailed) = CachePrune::Actions::run_elected_verbs($rt);
	report_delta($rt, $dir, $before, $vfailed) if $acted;
	if ($rt->{residue}) {
		$acted = 1 if $rt->{residue}->($rt);
	}
	print "$name: skipped.\n" unless $acted;
	return $vfailed ? 0 : 1;
}

sub print_total {
	CachePrune::Core::section('Total');
	printf "Total cache footprint seen:                   %s (%d bytes)\n", human_bytes($TOTAL_BYTES), $TOTAL_BYTES;
	printf "Estimated safe-tier reclaimable (upper bound): %s (%d bytes)\n", human_bytes($SAFE_RECLAIMABLE_BYTES), $SAFE_RECLAIMABLE_BYTES;
	printf "Estimated purge-tier reclaimable (--include-purge; trash interactive-only): %s (%d bytes)\n", human_bytes($PURGE_RECLAIMABLE_BYTES), $PURGE_RECLAIMABLE_BYTES;
	if ($OVERLAP_RECLAIMABLE_BYTES > 0) {
		printf "Overlap: %s (%d bytes) of the safe-tier figure is also inside the purge-tier figure (a purge verb that is a superset of its safe verb); the two are not additive.\n",
			human_bytes($OVERLAP_RECLAIMABLE_BYTES), $OVERLAP_RECLAIMABLE_BYTES;
	}
	if ($CachePrune::Core::MODE ne 'report') {
		printf "Observed footprint change (measured, not predicted): %s (%d bytes)\n", human_bytes_signed($DELTA_BYTES), $DELTA_BYTES;
	}
	print "Total counts every byte present, including any runtime with no verb; the safe- and purge-tier figures are separate per-verb estimates and are never summed into one number; the observed footprint change is what was actually measured before/after acting, not a prediction.\n";
}

# main(@args) -> exit status: 0 ok; 1 a runtime failed, root, no TTY or a usage error; 2 an
# invalid --docker-until window (the bash CLI's exact statuses).
sub main {
	my @args = @_;
	$CachePrune::Core::MODE = 'interactive';
	$CachePrune::Core::INCLUDE_PURGE = 0;
	$CachePrune::Core::DOCKER_UNTIL = '';
	$CachePrune::Core::FAILED = 0;
	reset_totals();
	while (@args) {
		my $a = shift @args;
		if ($a eq '--report') { $CachePrune::Core::MODE = 'report'; }
		elsif ($a eq '--yes') { $CachePrune::Core::MODE = 'yes'; }
		elsif ($a eq '--include-purge') { $CachePrune::Core::INCLUDE_PURGE = 1; }
		elsif ($a eq '--docker-until') {
			return usage_error() unless @args;
			return 2 unless set_docker_until(shift @args);
		} elsif ($a =~ /\A--docker-until=(.*)\z/s) {
			return 2 unless set_docker_until($1);
		} elsif ($a eq '-h' || $a eq '--help') {
			usage();
			return 0;
		} else {
			return usage_error();
		}
	}
	return 1 unless require_not_root();
	if ($CachePrune::Core::MODE eq 'interactive') {
		return 1 unless require_tty();
	}
	process_runtime($_) for @CachePrune::Runtime::ORDER;
	print_total();
	return $CachePrune::Core::FAILED ? 1 : 0;
}

1;
