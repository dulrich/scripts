# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# runtimes/docker.pm: the `docker` runtime -- docker's build cache (safe verb docker builder
# prune, purge verb docker builder prune -a), plus its image/container/volume residue (the
# detail and residue hooks, over CachePrune::DockerResidue in-process). A core runtime module
# (interface: CachePrune/Runtime.pm POD), loaded in the CachePrune::Runtime::CORE_ORDER slot.
# The port of runtimes/docker.sh and docker-residue.sh's orchestration. perl-base only; the
# residue hooks need JSON::PP and report `no JSON::PP on host` without it.
package CachePrune::Runtime::docker;
use strict;
use warnings;
use CachePrune::Core ();
use CachePrune::Measurement ();
use CachePrune::Actions ();
use CachePrune::Runtime ();
use CachePrune::DockerResidue ();

### build cache ###############################################################

# detect folds in the daemon preflight: a present CLI with a dead daemon (or no permission) is a
# graceful skip, so `docker info` succeeding is part of the predicate.
sub detect {
	return 0 unless CachePrune::Core::have_cmd('docker');
	my (undef, $rc) = CachePrune::Core::cmd_capture({ stderr => 'null' }, 'docker', 'info');
	return $rc == 0 ? 1 : 0;
}

sub absent {
	return CachePrune::Core::have_cmd('docker') ? 'docker daemon not reachable' : 'no docker on host';
}

# docker_size_to_bytes($token): one docker-rendered size token (decimal units) -> integer
# bytes, exactly as the bash awk twin: trailing letters stripped for the number (awk's numeric
# prefix), leading digits/dots stripped for the unit, an unknown unit multiplies by 1.
sub docker_size_to_bytes {
	my ($size) = @_;
	$size //= '';
	(my $num = $size) =~ s/[A-Za-z]+\z//;
	(my $unit = $size) =~ s/\A[0-9.]+//;
	my $n = $num =~ /\A[ \t\n]*([-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)/ ? $1 + 0 : 0;
	my %mul = (kB => 1000, MB => 1000 * 1000, GB => 1000 * 1000 * 1000, TB => 1000 * 1000 * 1000 * 1000);
	return int($n * ($mul{$unit} // 1));
}

# _last_field($raw, $match, $idx): awk-style: whitespace fields of the last line $match accepts.
sub _last_field {
	my ($raw, $match, $idx) = @_;
	my $v;
	for my $line (split /\n/, $raw) {
		my @f = split ' ', $line;
		$v = $f[$idx] // '' if $match->(@f);
	}
	return $v // '';
}

# docker_buildx_du_bytes($raw): the trailing `Total:` / `Reclaimable:` labelled lines, or ().
sub docker_buildx_du_bytes {
	my ($raw) = @_;
	my $total = _last_field($raw, sub { $_[0] =~ /\ATotal:/ }, 1);
	my $recl = _last_field($raw, sub { $_[0] =~ /\AReclaimable:/ }, 1);
	return () unless length $total && length $recl;
	return (docker_size_to_bytes($total), docker_size_to_bytes($recl));
}

# docker_system_df_bytes($raw): plain `docker system df`'s two-word Build Cache row: SIZE ($5)
# and RECLAIMABLE ($6), a trailing "(NN%)" stripped; () when there is no such row.
sub docker_system_df_bytes {
	my ($raw) = @_;
	my $bc = sub { ($_[0] // '') eq 'Build' && ($_[1] // '') eq 'Cache' };
	my $total = _last_field($raw, $bc, 4);
	my $recl = _last_field($raw, $bc, 5);
	$recl =~ s/\(.*\z//s;
	return () unless length $total && length $recl;
	return (docker_size_to_bytes($total), docker_size_to_bytes($recl));
}

# size: system df's Build Cache row first (it predicts what the unfiltered safe prune frees),
# buildx du second, unavailable if both fail -- the source named in the record, so a
# before/after pair from different sources reports its delta unavailable.
sub size {
	my ($raw, $rc) = CachePrune::Core::cmd_capture({ stderr => 'null' }, 'docker', 'system', 'df');
	if ($rc == 0) {
		my @p = docker_system_df_bytes($raw);
		return CachePrune::Measurement::probe_available(@p, 'system-df') if @p;
	}
	($raw, $rc) = CachePrune::Core::cmd_capture({ stderr => 'null' }, 'docker', 'buildx', 'du');
	if ($rc == 0) {
		my @p = docker_buildx_du_bytes($raw);
		return CachePrune::Measurement::probe_available(@p, 'buildx-du') if @p;
	}
	return CachePrune::Measurement::probe_unavailable();
}

# prune: only the build-cache prune, unfiltered unless --docker-until opted into an age window
# (no --filter argument at all by default). Never image/system prune.
sub prune {
	my $until = $CachePrune::Core::DOCKER_UNTIL;
	my @f = (defined $until && length $until) ? ('--filter', "until=$until") : ();
	return CachePrune::Core::cmd_run('docker', 'builder', 'prune', @f, '--force') == 0;
}

# purge: the whole unused build cache; never filtered, whatever --docker-until says.
sub purge { return CachePrune::Core::cmd_run('docker', 'builder', 'prune', '-a', '--force') == 0; }

### residue: capture and classification #########################################

# repo_root: the root searched for compose files; unset or empty means no compose search.
sub repo_root { return $ENV{CACHE_PRUNE_REPO_ROOT} // ''; }

# classify_rows(): (status, rows) of a fresh capture: ('ok', rows...) or ('failed') when the
# classifier dies or prints nothing (a healthy run always prints a volume or unavailable row).
sub classify_rows {
	my @rows = eval {
		my $doc = CachePrune::DockerResidue::capture(repo_root());
		CachePrune::DockerResidue::classify_text($doc);
	};
	return ('failed') if $@ || !@rows;
	return ('ok', @rows);
}

# _fields($row): the row split as bash `IFS=$'\t' read` does (tab runs collapse, edge tabs
# trimmed).
sub _fields { my $r = shift; $r =~ s/\A\t+//; $r =~ s/\t+\z//; return split /\t+/, $r; }

sub _num { my $v = shift; return (defined $v && $v =~ /\A-?[0-9]+\z/) ? $v : 0; }
sub _hb { return CachePrune::Measurement::human_bytes(_num($_[0])); }

sub short_id { my $id = shift // ''; $id =~ s/\Asha256://; return substr($id, 0, 12); }
sub _day { my $d = shift // ''; $d =~ s/T.*\z//s; return $d; }

### residue: report (detail hook) ###############################################

sub report {
	my @rows = @_;
	my (%seen_sup, %seen_unref);
	my ($sup_bytes, $unref_bytes, $stale_bytes, $stale_unknown) = (0, 0, 0, 0);
	my ($sup_n, $unref_n, $stale_n, $vol_n, $vol_dangling, $vol_dangling_bytes, $anon_n, $anon_bytes) = (0) x 8;
	my ($img_un, $vol_un) = ('', '');
	my ($sup_lines, $unref_lines, $stale_lines, $vol_lines) = ('', '', '', '');
	for my $row (@rows) {
		my ($class, $a, $b, $c, $d, $e, $f) = map { $_ // '' } _fields($row);
		if ($class eq 'superseded' || $class eq 'unreferenced') {
			my $line = sprintf('  %s  %s  %s  created %s%s', $a, short_id($b), _hb($c), _day($d),
				$e ne '-' ? "  blocked by stale container(s): $e" : '') . "\n";
			if ($class eq 'superseded') {
				$sup_lines .= $line; $sup_n++;
				$sup_bytes += _num($c) unless $seen_sup{$b}++;
			} else {
				$unref_lines .= $line; $unref_n++;
				$unref_bytes += _num($c) unless $seen_unref{$b}++;
			}
		} elsif ($class eq 'stale') {
			$stale_n++;
			if ($c =~ /\A[0-9]+\z/) { $stale_bytes += $c; $c = CachePrune::Measurement::human_bytes($c); }
			else { $stale_unknown = 1; }
			$stale_lines .= sprintf("  %s  %s  image %s (%s)  writable layer %s  created %s\n",
				$a, $e, $f, short_id($b), $c, _day($d));
		} elsif ($class eq 'volume') {
			$vol_n++;
			if ($d eq 'dangling') { $vol_dangling++; $vol_dangling_bytes += _num($b); }
			$vol_lines .= sprintf("  %s  %s  links %s%s\n", $a, _hb($b), $c, $d eq 'dangling' ? '  [dangling]' : '');
		} elsif ($class eq 'anonvolume') {
			$anon_n++; $anon_bytes += _num($b);
		} elsif ($class eq 'unavailable') {
			if ($a eq 'images') { $img_un = $b; } else { $vol_un = $b; }
		}
	}
	my $hb = \&CachePrune::Measurement::human_bytes;
	if (length $img_un) {
		print "docker superseded images: unavailable ($img_un)\n";
		print "docker unreferenced images: unavailable ($img_un)\n";
		print "docker stale containers: unavailable ($img_un)\n";
	} else {
		printf "docker superseded images: %s (%d bytes, %d tags) (safe tier, upper bound: shared layers)\n", $hb->($sup_bytes), $sup_bytes, $sup_n;
		print $sup_lines;
		printf "docker unreferenced images: %s (%d bytes, %d tags) (purge tier, per-image confirm, upper bound)\n", $hb->($unref_bytes), $unref_bytes, $unref_n;
		print $unref_lines;
		if ($stale_unknown) {
			printf "docker stale containers: %d, writable layers unavailable (purge tier; container bytes are not image bytes)\n", $stale_n;
		} else {
			printf "docker stale containers: %d, writable layers %s (%d bytes) (purge tier; container bytes are not image bytes)\n", $stale_n, $hb->($stale_bytes), $stale_bytes;
		}
		print $stale_lines;
		print "note: docker image/container residue is not counted in the totals below; outside --report it is acted on after the build-cache prune (superseded under --yes, stale containers with --include-purge, unreferenced only per-image interactively).\n";
	}
	if (length $vol_un) {
		print "docker volumes: unavailable ($vol_un)\n";
		print "docker anonymous volumes: unavailable ($vol_un)\n";
	} else {
		printf "docker volumes: %d (%d dangling, %s / %d bytes) -- %d named dangling: report-only, no verb (named volumes are never removed)\n",
			$vol_n, $vol_dangling, $hb->($vol_dangling_bytes), $vol_dangling_bytes, $vol_dangling - $anon_n;
		print $vol_lines;
		printf "docker anonymous volumes: %d dangling, %s (%d bytes) (purge tier, removed by name)\n", $anon_n, $hb->($anon_bytes), $anon_bytes;
	}
}

# detail: captures once and prints; never part of the probe record.
sub detail {
	my $reason = CachePrune::DockerResidue::json_reason();
	if (length $reason) { print "docker image/container/volume residue: unavailable ($reason)\n"; return; }
	my ($st, @rows) = classify_rows();
	if ($st ne 'ok') { print "docker image/container/volume residue: unavailable (classifier failed)\n"; return; }
	report(@rows);
}

### residue: removal (residue hook) ##############################################

# footprint(): Images + Containers + Local Volumes bytes from `docker system df --format json`,
# or undef -- never a guess.
sub footprint {
	my ($out, $rc) = CachePrune::Core::cmd_capture({ stderr => 'null' }, 'docker', 'system', 'df', '--format', 'json');
	return undef unless $rc == 0 && length $out;
	my $b = eval { CachePrune::DockerResidue::footprint($out) };
	return (defined $b && $b =~ /\A[0-9]+\z/) ? $b : undef;
}

sub footprint_probe {
	my $b = footprint();
	return defined $b ? CachePrune::Measurement::probe_available($b, 0, 'docker-system-df')
		: CachePrune::Measurement::probe_unavailable();
}

# remove_item($kind, $target): one item, never forced; a failure is a per-item warning.
sub remove_item {
	my ($kind, $target) = @_;
	my @cmd = $kind eq 'container' ? ('rm') : $kind eq 'volume' ? ('volume', 'rm') : ('rmi');
	my (undef, $rc) = CachePrune::Core::cmd_capture('docker', @cmd, $target);
	return 1 if $rc == 0;
	CachePrune::Core::warn_msg("docker: could not remove $kind $target (left in place)");
	return 0;
}

# residue: from a FRESH classification. Elections: superseded -- safe tier; stale containers
# and anonymous dangling volumes -- purge tier; unreferenced -- per-image confirm only
# (interactive --include-purge). Order: stale containers, anonymous volumes (those dangling
# before this run's removals and still in a fresh capture), superseded, unreferenced.
sub residue {
	my $reason = CachePrune::DockerResidue::json_reason();
	if (length $reason) { print "docker residue: nothing elected ($reason)\n"; return 0; }
	my ($st, @rows) = classify_rows();
	if ($st ne 'ok') { print "docker residue: nothing elected (classifier failed)\n"; return 0; }
	for my $r (@rows) {
		my @f = split /\t/, $r, -1;
		if (($f[0] // '') eq 'unavailable' && ($f[1] // '') eq 'images') {
			print 'docker residue: nothing elected (images unavailable: ' . ($f[2] // '') . ")\n";
			return 0;
		}
	}
	my (@sup, @stale, @unref, @unref_target, @unref_size, %sup_seen, %anon_before);
	my ($sup_bytes, $anon_bytes, $anon_n) = (0, 0, 0);
	for my $r (@rows) {
		my ($class, $a, $b, $c) = map { $_ // '' } _fields($r);
		if ($class eq 'superseded') {
			push @sup, $a;
			$sup_bytes += _num($c) unless $sup_seen{$b}++;
		} elsif ($class eq 'unreferenced') {
			push @unref, $a;
			push @unref_target, $a eq '<none>' ? $b : $a;
			push @unref_size, _hb($c);
		} elsif ($class eq 'stale') {
			push @stale, $a;
		} elsif ($class eq 'anonvolume') {
			$anon_n++ unless $anon_before{$a}++;
			$anon_bytes += _num($b);
		}
	}
	my $hb = \&CachePrune::Measurement::human_bytes;
	my $te = \&CachePrune::Actions::tier_elected;
	my $do_sup = @sup && $te->('safe', 'Remove ' . scalar(@sup) . ' superseded docker image tags (' . $hb->($sup_bytes) . ')?');
	my $do_stale = @stale && $te->('purge', 'Remove ' . scalar(@stale) . " stale docker containers (@stale)? (purge tier)");
	my $do_vol = $anon_n && $te->('purge', "Remove $anon_n anonymous dangling docker volumes (" . $hb->($anon_bytes) . ')? (purge tier)');

	my $mode = $CachePrune::Core::MODE;
	my $before = CachePrune::Measurement::probe_unavailable();
	$before = footprint_probe() if $do_sup || $do_stale || $do_vol
		|| ($mode eq 'interactive' && $CachePrune::Core::INCLUDE_PURGE && @unref);

	my $acted = 0;
	my $summary = '';
	my ($ok, $fail) = (0, 0);
	my $tally = sub { if ($_[0]) { $ok++ } else { $fail++ } };
	if ($do_stale) { $acted = 1; $tally->(remove_item('container', $_)) for @stale; }
	$summary .= "stale containers removed $ok, failed $fail; ";

	($ok, $fail) = (0, 0);
	if ($do_vol) {
		my @names;
		my ($vst, @vrows) = classify_rows();
		if ($vst eq 'ok' && !grep { /\Aunavailable\tvolumes\t/ } @vrows) {
			for my $r (@vrows) {
				my ($class, $a) = map { $_ // '' } _fields($r);
				push @names, $a if $class eq 'anonvolume' && $anon_before{$a};
			}
		} else {
			print "docker anonymous volumes: nothing elected (fresh volume capture unavailable)\n";
		}
		for my $n (@names) { $acted = 1; $tally->(remove_item('volume', $n)); }
	}
	$summary .= "anonymous volumes removed $ok, failed $fail; ";

	($ok, $fail) = (0, 0);
	if ($do_sup) { $acted = 1; $tally->(remove_item('image', $_)) for @sup; }
	$summary .= "superseded tags removed $ok, failed $fail; ";

	($ok, $fail) = (0, 0);
	if (@unref) {
		if ($mode eq 'yes') {
			printf "skipped: %d unreferenced images need a per-image interactive confirm\n", scalar @unref;
		} else {
			for my $i (0 .. $#unref) {
				next unless $te->('item', "Remove unreferenced docker image $unref[$i] ($unref_size[$i])? (purge tier)");
				$acted = 1;
				$tally->(remove_item('image', $unref_target[$i]));
			}
		}
	}
	$summary .= "unreferenced images removed $ok, failed $fail";

	if (!$acted) { print "docker residue: nothing removed\n"; return 0; }
	print "docker residue: $summary\n";
	my $after = CachePrune::Measurement::probe_unavailable();
	$after = footprint_probe() if CachePrune::Measurement::probe_is_available($before);
	my $cmp = CachePrune::Measurement::probe_compare('docker-residue', $before, $after);
	if ($cmp =~ /\Aavailable (-?[0-9]+)\z/) {
		printf "docker images/containers/volumes: observed footprint change %s (%d bytes)\n",
			CachePrune::Measurement::human_bytes_signed($1), $1;
	} else {
		print "docker images/containers/volumes: observed footprint change unavailable (docker system df --format json reading failed)\n";
	}
	return 1;
}

CachePrune::Runtime::register_runtime({
	name => 'docker',
	detect => \&detect,
	absent => \&absent,
	# No cache_dir hook: docker's build cache is daemon-owned, not a directory to resolve or du.
	size => \&size,
	prune => \&prune,
	purge => \&purge,
	purge_unpredicted_note => 'docker purge verb (docker builder prune -a) clears the whole unused build cache, up to the total above, not just the safe-verb figure -- requires --include-purge',
	safe_estimate_note => 'note: docker reclaimable is an upper bound (not pinned by an active build), not a guarantee of what a prune will free.',
	detail => \&detail,
	residue => \&residue,
});

1;
