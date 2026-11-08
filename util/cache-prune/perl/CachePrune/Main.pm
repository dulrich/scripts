# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# CachePrune::Main: the command-line surface, the per-runtime lifecycle (detect/resolve,
# measure/report, elect/run, measure/report the outcome) and the Total block. Every runtime is
# a registered module (CachePrune::Runtime). Runtime-specific prose (help text) lives in the runtime
# modules; only fixed CLI and discovery names stay here: the --docker-until flag and its validation,
# the root-refusal message, the trash note in the Total label and @CORE_ORDER (Runtime.pm). Sentences
# naming several runtimes derive the names from the registry (core set, filtered by hook). perl-base only.
package CachePrune::Main;
use strict;
use warnings;
use CachePrune::Core ();
use CachePrune::Measurement qw(probe_is_record probe_is_available probe_compare
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

# The name usage errors print: CACHE_PRUNE_SHIM (the util/cache-prune.sh shim's own path), else $0.
sub prog_name { return (defined $ENV{CACHE_PRUNE_SHIM} && length $ENV{CACHE_PRUNE_SHIM}) ? $ENV{CACHE_PRUNE_SHIM} : $0; }

sub reset_totals {
	$TOTAL_BYTES = $SAFE_RECLAIMABLE_BYTES = $PURGE_RECLAIMABLE_BYTES = 0;
	$OVERLAP_RECLAIMABLE_BYTES = $DELTA_BYTES = 0;
}

### usage #####################################################################

sub _frag { print "$_\n" for @{ $CachePrune::Runtime::HELP{ $_[0] } }; }

# Core runtimes (a discovery fact: @CORE_ORDER membership), in registry order, filtered by a
# hook predicate. Help sentences that name several runtimes derive their names from here; fleet
# runtimes registered by the overlay are excluded so the help stays the core's.
sub _core_names {
	my ($want) = @_;
	my %core = map { $_ => 1 } @CachePrune::Runtime::CORE_ORDER;
	return map { $_->{name} } grep { $core{ $_->{name} } && $want->($_) } @CachePrune::Runtime::ORDER;
}

# "a", "a and b", "a, b and c".
sub _and_list {
	my @n = @_;
	return pop @n unless @n > 1;
	my $last = pop @n;
	return join(', ', @n) . " and $last";
}

sub usage {
	my @cached = _core_names(sub { !$_[0]{interactive_only} });
	my @trashy = _core_names(sub { $_[0]{interactive_only} });
	my @safe = _core_names(sub { $_[0]{prune} });
	my @purge_only = _core_names(sub { $_[0]{purge} && !$_[0]{prune} && !$_[0]{interactive_only} });
	my @both = _core_names(sub { $_[0]{prune} && $_[0]{purge} });
	my $both_head = shift @both;
	my $both_rest = _and_list(@both);
	my $cached = join ', ', @cached;
	my $trashy = join ', ', @trashy;
	my $safe = join ', ', @safe;
	my $purge_only = _and_list(@purge_only);
	# Inline slot: fragments are joined into the template mid-line, not printed as lines.
	my $caveat = join '; ', @{ $CachePrune::Runtime::HELP{core_purge_caveat} };
	print <<'TXT';
usage: cache-prune [--report | --yes [--include-purge]]
                    [--docker-until <window>] [-h|--help]

TXT
	print <<TXT;
Reports (and, outside --report, optionally prunes) rebuildable
language-runtime caches ($cached) plus the
home trash ($trashy) for the invoking user. Refuses to run as root.

Modes:
  (default)              interactive; per-runtime confirm (default: No)
  --report               report cache sizes only; never prompts, never mutates
  --yes                  auto-confirm the safe verb for $safe;
                         $purge_only have no safe verb and are
                         skipped entirely, never prompted; $trashy is never
                         emptied under --yes
  --yes --include-purge  purges $purge_only (their only verb;
                         $caveat); for $both_head,
                         $both_rest this instead runs their purge verb in
                         place of their safe verb, not in addition to it; $trashy
                         is still skipped (interactive confirm only)

TXT
	_frag('core_verbs');
	print <<'TXT';

TXT
	_frag('core_residue');
	print <<'TXT';

Options:
TXT
	_frag('core_options');
	print <<'TXT';
  -h, --help               show this help and exit

TXT
	_frag('runtimes');
	_frag('core_runtimes');
	print <<'TXT';
Notes:
TXT
	_frag('core_notes_safe');
	_frag('core_notes_purge');
	print "\n";
	_frag('core_notes_delta');
	print "\nHonoured environment:\n";
	_frag('core_env_lead');
	_frag('core_env_residue');
	_frag('env');
	_frag('core_env');
}

### guards ####################################################################

# usage_error: exit status 2, like every usage error (unknown flag, --docker-until without a
# value, a rejected window).
sub usage_error {
	CachePrune::Core::die_msg('usage: ' . prog_name()
		. ' [--report|--yes] [--include-purge] [--docker-until <window>] [-h|--help]');
	return 2;
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
	return (2) unless probe_is_record($r);
	return (0, $r);
}

# report_measurement($rt, $total, $reclaimable): the reclaimable lines follow from the verb hooks
# and the registry's predicts ('purge' | 'safe'): both verbs + safe_reclaimable -- split safe and
# purge lines; a predicted purge verb -- the purge line (plus the unpredictable-safe-verb note
# when a prune hook exists too); a predicted safe verb -- the safe line. report_notes follow.
sub report_measurement {
	my ($rt, $total, $recl) = @_;
	my $name = $rt->{name};
	printf "%s cache size: %s total (%d bytes)\n", $name, human_bytes($total), $total;
	$TOTAL_BYTES += $total;
	my $predicts = $rt->{predicts} // '';
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
	} elsif ($rt->{purge} && $predicts eq 'purge') {
		my $gate = 'requires --include-purge';
		$gate = 'emptied only after an interactive confirm, never under --yes'
			if defined $rt->{interactive_only} && length $rt->{interactive_only};
		printf "%s reclaimable via the purge verb (%s, %d bytes) -- %s\n", $name, human_bytes($recl), $recl, $gate;
		$PURGE_RECLAIMABLE_BYTES += $recl;
		if ($rt->{prune}) {
			print "note: ${name}'s safe verb cannot be predicted (no dry run exists) -- it is not represented by any reclaimable figure here.\n";
		}
	} elsif ($rt->{prune} && $predicts eq 'safe') {
		printf "%s reclaimable via the safe verb (%s, %d bytes)\n", $name, human_bytes($recl), $recl;
		$SAFE_RECLAIMABLE_BYTES += $recl;
	}
	print "$_\n" for @{ $rt->{report_notes} // [] };
}

# report_delta($rt, $dir, $before, $verb_failed): one post-action probe spanning every verb.
sub report_delta {
	my ($rt, $dir, $before, $verb_failed) = @_;
	my $name = $rt->{name};
	my ($st, $after) = measure_runtime($rt, $dir);
	$after = undef if $st != 0;
	my ($delta, $reason) = probe_compare($name, $before, $after);
	if (!defined $delta) {
		print "$name: observed footprint change: unavailable ($reason)\n";
		return;
	}
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
	report_measurement($rt, $before->{total}, $before->{reclaimable});
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

# main(@args) -> exit status: 0 ok; 1 a runtime failed, root or no TTY; 2 a usage error (an
# unknown flag, --docker-until without a value or with an invalid window).
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
