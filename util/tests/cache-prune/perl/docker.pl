#!/usr/bin/perl
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# In-process cases for the perl docker and trash runtimes and CachePrune::DockerResidue, run by
# ./run.sh: `perl docker.pl <cache-prune.pl> <sandbox> <fixture-dir>`. The entrypoint is loaded
# with `require`; the command seam (cmd_capture/cmd_run/have_cmd), the residue capture's
# run_cmd and confirm are replaced by a fake docker/gio that answers from in-memory fixtures and
# logs every call, so nothing reaches a real daemon. Only du (trash sizing) runs for real, on
# sandbox paths. The port of the bash docker-residue.sh and trash.sh suites plus the docker
# cases of adapters/measurement/actions/cli/missing-tool.
use strict;
use warnings;
no warnings qw(redefine once);
use Cwd ();
use File::Basename ();
BEGIN { unshift @INC, File::Basename::dirname(Cwd::realpath($ARGV[0])) if @ARGV && -e $ARGV[0]; }
use JSON::PP ();

my ($prog, $SB, $FIXD) = @ARGV;
die "usage: docker.pl <cache-prune.pl> <sandbox> <fixture-dir>\n" unless defined $FIXD && -d $SB && -d $FIXD;
$SB = Cwd::realpath($SB);
$prog = Cwd::realpath($prog);
$FIXD = Cwd::realpath($FIXD);
mkdir "$SB/empty-fleet";
$ENV{CACHE_PRUNE_FLEET_DIR} = "$SB/empty-fleet";
$ENV{HOME} = "$SB/home";
mkdir $ENV{HOME};
delete @ENV{qw(CACHE_PRUNE_REPO_ROOT CACHE_PRUNE_COMPOSE_PROJECT_DIRS CACHE_PRUNE_TRASH_DIR CACHE_PRUNE_GIO XDG_DATA_HOME)};
require $prog;
main::cache_prune_load();

my ($pass, $fail) = (0, 0);
sub ok { $pass++; print "  ok   - $_[0]\n"; }
sub bad { $fail++; print "  FAIL - $_[0]\n"; }
sub is_eq { my ($exp, $got, $label) = @_; $got = '<undef>' unless defined $got; $exp eq $got ? ok($label) : bad("$label (expected <$exp>, got <$got>)"); }
sub has { my ($hay, $needle, $label) = @_; index($hay, $needle) >= 0 ? ok($label) : bad("$label (expected <$needle> in <$hay>)"); }
sub hasnt { my ($hay, $needle, $label) = @_; index($hay, $needle) < 0 ? ok($label) : bad("$label (did not expect <$needle> in <$hay>)"); }
sub section { print "$_[0]\n"; }

my $capn = 0;
sub capture {
	my ($code) = @_;
	$capn++;
	my ($fo, $fe) = ("$SB/dcap$capn.out", "$SB/dcap$capn.err");
	STDOUT->flush; STDERR->flush;
	open(my $so, '>&', \*STDOUT) or die; open(my $se, '>&', \*STDERR) or die;
	open(STDOUT, '>', $fo) or die; open(STDERR, '>', $fe) or die;
	my @r = $code->();
	STDOUT->flush; STDERR->flush;
	open(STDOUT, '>&', $so) or die; open(STDERR, '>&', $se) or die;
	my $slurp = sub { open(my $h, '<', $_[0]) or return ''; local $/; my $c = <$h>; return $c // ''; };
	return ($slurp->($fo), $slurp->($fe), @r);
}

# ---- the fake docker / gio ---------------------------------------------------------
our (@ALL, @MUTATE, @CONFIRM_LOG);
our $CONFIRM_YES = '';         # a confirm is accepted when its prompt contains this
our %PRESENT;
our %FX;                       # fixture state, reset by fx_reset
my $J = JSON::PP->new->canonical;
my $SYSTEM_DF = "TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE\nImages          12        4         3.2GB     1.1GB (34%)\nContainers      5         2         50MB      10MB (20%)\nLocal Volumes   8         3         500MB     50MB (10%)\nBuild Cache     42        0         10GB      6GB (60%)\n";
my $BUILDX_DU = "ID             RECLAIMABLE  SIZE       LAST ACCESSED\naaaa1111aaaa   true         2.5GB*     3 days ago\nbbbb2222bbbb   true         500MB      10 days ago\nShared:\t\t2.5GB\nPrivate:\t8GB\nReclaimable:\t4GB\nTotal:\t\t10GB\n";
my $IMAGES = '[{"Id":"sha256:old","RepoTags":["webapp-overlay:v0.11.3"],"Created":"2026-01-01T00:00:00Z","Size":5},{"Id":"sha256:old1","RepoTags":["webapp-overlay:v0.11.1"],"Created":"2025-12-01T00:00:00Z","Size":4},{"Id":"sha256:overlay","RepoTags":["webapp-overlay:v0.11.4"],"Created":"2026-09-01T00:00:00Z","Size":7},{"Id":"sha256:ua","RepoTags":["orphan-a:1"],"Created":"2026-02-01T00:00:00Z","Size":11},{"Id":"sha256:ub","RepoTags":["orphan-b:1"],"Created":"2026-02-01T00:00:00Z","Size":13}]';
my $CONTAINERS = '[{"Name":"/gone-x-1","Id":"c1","Image":"sha256:ua","Config":{"Image":"orphan-a:1","Labels":{"com.docker.compose.project":"gone","com.docker.compose.service":"x"}},"State":{"Status":"exited"},"Created":"2026-02-02T00:00:00Z"}]';
my $DF_JSON = qq({"Type":"Images","Size":"40B"}\n{"Type":"Containers","Size":"1kB"}\n{"Type":"Local Volumes","Size":"5MB"});
my $ANON_VOLS = '[{"Name":"anon-a","Size":"2MB","Links":"0","Labels":"com.docker.volume.anonymous="},{"Name":"anon-b","Size":"3MB","Links":"0","Labels":"com.example.x=1,com.docker.volume.anonymous="},{"Name":"anon-linked","Size":"1MB","Links":"1","Labels":"com.docker.volume.anonymous="},{"Name":"named-d","Size":"5MB","Links":"0","Labels":"com.docker.compose.project=p"},{"Name":"lookalike","Size":"1kB","Links":"0","Labels":"com.docker.volume.anonymous.not=1,x=com.docker.volume.anonymous"}]';
sub slurp_file { open(my $h, '<', $_[0]) or die "$_[0]: $!"; local $/; return scalar <$h>; }
(my $COMPOSE_FIX = slurp_file("$FIXD/compose-config.json")) =~ s/\@FIXTURES\@/$FIXD/g;
sub fx_reset {
	%FX = (info => 0, df => $SYSTEM_DF, df_rc => 0, buildx => $BUILDX_DU, buildx_rc => 0, df_fail_after_prune => 0,
		images => '[{"Id":"sha256:old","RepoTags":["webapp-overlay:v0.11.3"],"Created":"2026-01-01T00:00:00Z","Size":5},{"Id":"sha256:overlay","RepoTags":["webapp-overlay:v0.11.4"],"Created":"2026-09-01T00:00:00Z","Size":7}]',
		containers => '[]', compose => $COMPOSE_FIX, compose_rc => 0, volumes => '[{"Name":"orphan-vol","Size":"43.35MB","Links":"0"}]',
		volumes_after_rm => '', volumes_rc => 0, df_json => '', rm_fail => '', fp => undef, gio_rc => 0);
}
sub ids_of { return join("\n", map { $_->{Id} } @{ $J->decode($_[0]) }); }
sub fake_docker {
	my @a = @_;
	my $line = "@a";
	push @ALL, "docker $line";
	if ($line =~ /\A(?:builder prune|rmi |rm |volume rm )/) {
		push @MUTATE, "docker $line";
		return ('', 1) if length $FX{rm_fail} && $a[-1] eq $FX{rm_fail} && $line !~ /\Abuilder/;
		return ('', 0);
	}
	return ('', $FX{info}) if $line eq 'info';
	if ($line eq 'system df') {
		return ('', 1) if $FX{df_fail_after_prune} && grep { /\Adocker builder prune/ } @MUTATE;
		return ($FX{df}, $FX{df_rc});
	}
	return ($FX{buildx}, $FX{buildx_rc}) if $line eq 'buildx du';
	if ($line eq 'system df -v --format json') {
		return ('', 1) if $FX{volumes_rc};
		my $v = (length $FX{volumes_after_rm} && grep { /\Adocker rm / } @MUTATE) ? $FX{volumes_after_rm} : $FX{volumes};
		return ("{\"Volumes\":$v}", 0);
	}
	if ($line eq 'system df --format json') {
		if (ref $FX{fp} eq 'ARRAY') {
			my $v = shift @{ $FX{fp} } // 'fail';
			return $v eq 'fail' ? ('', 1) : (qq({"Type":"Images","Size":"${v}B"}\n{"Type":"Containers","Size":"0B"}\n{"Type":"Local Volumes","Size":"0B"}), 0);
		}
		return length $FX{df_json} ? ($FX{df_json}, 0) : ('', 1);
	}
	return ('', 0) if $line eq 'compose version';
	return ($FX{compose}, $FX{compose_rc}) if $line =~ /\Acompose -f /;
	return (ids_of($FX{images}), 0) if $line eq 'images -q --no-trunc';
	return ($FX{images}, 0) if $line =~ /\Aimage inspect/;
	return (ids_of($FX{containers}), 0) if $line eq 'ps -aq --no-trunc';
	return (join("\n", map { $J->encode({ id => $_->{Id}, size => '1kB' }) } @{ $J->decode($FX{containers}) }), 0) if $line =~ /\Aps -a --size/;
	return ($FX{containers}, 0) if $line =~ /\Acontainer inspect/;
	return ('', 1);
}
sub fake_cmd {
	my @c = @_;
	shift @c if ref $c[0] eq 'HASH';
	my $n = shift @c;
	return fake_docker(@c) if $n eq 'docker';
	if ($n eq 'gio' || $n =~ m{/gio\z}) { push @ALL, "gio @c"; push @MUTATE, "gio @c"; return ('', $FX{gio_rc}); }
	return CachePrune::Core::_real_capture(@_) if $n eq 'du';
	push @ALL, "$n @c";
	return ('', 0);
}
my $real_capture = \&CachePrune::Core::cmd_capture;
*CachePrune::Core::_real_capture = $real_capture;
*CachePrune::Core::cmd_capture = sub { return fake_cmd(@_); };
*CachePrune::Core::cmd_run = sub { return (fake_cmd(@_))[1]; };
*CachePrune::Core::have_cmd = sub { return $PRESENT{ $_[0] } ? 1 : 0; };
*CachePrune::Core::confirm = sub { push @CONFIRM_LOG, $_[0]; return (length $CONFIRM_YES && index($_[0], $CONFIRM_YES) >= 0) ? 1 : 0; };
*CachePrune::DockerResidue::run_cmd = sub { my ($out, $rc) = fake_docker(@_[1 .. $#_]); return ($rc == 0, $out); };

sub reset_logs { @ALL = (); @MUTATE = (); @CONFIRM_LOG = (); $CONFIRM_YES = ''; $CachePrune::Core::FAILED = 0; $CachePrune::Core::DOCKER_UNTIL = ''; CachePrune::Main::reset_totals(); }
sub mode { ($CachePrune::Core::MODE, $CachePrune::Core::INCLUDE_PURGE) = @_; $CachePrune::Core::INCLUDE_PURGE //= 0; }
sub rt { return $CachePrune::Runtime::BY_NAME{ $_[0] } // die "no runtime $_[0]\n"; }
sub proc { my ($name) = @_; return capture(sub { CachePrune::Main::process_runtime(rt($name)) }); }
sub mutate { return join('', map { "$_|" } @MUTATE); }
sub confirms { return join('', map { "$_|" } @CONFIRM_LOG); }
sub all_log { return join('', map { "$_|" } @ALL); }
sub F { return $CachePrune::Core::FAILED; }
%PRESENT = (docker => 1, gio => 1);
fx_reset();

my $D = 'CachePrune::Runtime::docker';
my $DR = 'CachePrune::DockerResidue';
no strict 'refs';
sub dsub { my $n = shift; return &{"CachePrune::Runtime::docker::$n"}(@_); }
use strict 'refs';
sub classify_doc { return join("\n", CachePrune::DockerResidue::classify_text($_[0])); }
sub capture_doc { local $ENV{CACHE_PRUNE_REPO_ROOT} = $_[0] if defined $_[0]; return CachePrune::DockerResidue::capture(CachePrune::Runtime::docker::repo_root()); }
sub field { my ($doc, $k) = @_; my $v = $J->decode($doc)->{$k}; return ref $v ? join("\n", @$v) : defined $v ? $v : 'null'; }

# ---- adapters.sh: docker ---------------------------------------------------------------
section('[docker] registry membership: dual verb, daemon-owned cache, residue hooks');
is_eq('prune purge detail residue', join(' ', grep { rt('docker')->{$_} } qw(prune purge cache_dir detail residue)), 'docker has prune, purge, detail and residue, and no cache_dir hook');
has(rt('docker')->{purge_unpredicted_note}, 'docker builder prune -a', 'the size probe predicts the safe verb only: the purge figure is a note');

section('[docker] daemon-down is a skip, not a failure');
reset_logs(); mode('yes'); $FX{info} = 1;
my ($out, $err) = proc('docker');
has($out, 'skip: docker: docker daemon not reachable', 'a present CLI with a dead daemon keeps its own reason');
hasnt(all_log(), 'docker system', 'daemon-down docker never reaches system df');
is_eq('', mutate(), 'daemon-down docker never prunes');
is_eq('0', F(), 'daemon-down docker is a skip, not a failure');
fx_reset();

section('[missing tool] docker: a missing CLI is named');
delete $PRESENT{docker}; reset_logs();
($out) = proc('docker');
has($out, 'skip: docker: no docker on host', 'a missing docker CLI is named');
is_eq('0 ', F() . ' ' . all_log(), 'a missing docker CLI is no failure and runs nothing');
$PRESENT{docker} = 1;

section('[docker parse] unit normalization and the shared size vectors (docker_size_to_bytes, hbytes)');
for my $v (['500B', 500], ['512kB', 512000], ['2.5MB', 2500000], ['4GB', 4000000000], ['3TB', 3000000000000], ['1.5kB', 1500], ['0B', 0]) {
	is_eq($v->[1], CachePrune::Runtime::docker::docker_size_to_bytes($v->[0]), "docker_size_to_bytes: $v->[0] is $v->[1] bytes");
	is_eq($v->[1], CachePrune::DockerResidue::hbytes($v->[0]), "hbytes: $v->[0] is $v->[1] bytes");
}
is_eq('2', CachePrune::Runtime::docker::docker_size_to_bytes('2.052GB*'), 'a starred token parses as the bash awk does (unknown unit multiplies by 1)');

section('[docker parse] buildx du labels and the system df Build Cache row');
is_eq('10000000000 4000000000', join(' ', CachePrune::Runtime::docker::docker_buildx_du_bytes($BUILDX_DU)), "Total:/Reclaimable: labels parse despite a preceding '*' shared-marker row");
is_eq('10000000000 6000000000', join(' ', CachePrune::Runtime::docker::docker_system_df_bytes($SYSTEM_DF)), 'SIZE/RECLAIMABLE parse from the two-word Build Cache row, percentage stripped');
is_eq('', join(' ', CachePrune::Runtime::docker::docker_system_df_bytes("Images space usage:\n\nno build-cache row here at all\n")), 'no Build Cache row parses as nothing');

section('[docker] size: system df first, buildx du fallback, unavailable when both fail');
reset_logs();
is_eq('available 10000000000 6000000000 system-df', rt('docker')->{size}->(rt('docker'), ''), 'system df is the primary source, named in the record');
hasnt(all_log(), 'buildx du', 'buildx du is never queried when system df succeeded');
reset_logs(); $FX{df_rc} = 1;
is_eq('available 10000000000 4000000000 buildx-du', rt('docker')->{size}->(rt('docker'), ''), 'a failing system df falls back to buildx du, named in the record');
has(all_log(), 'docker system df|docker buildx du|', 'system df is attempted first');
reset_logs(); $FX{df} = "no build-cache row\n"; $FX{df_rc} = 0; $FX{buildx_rc} = 1;
is_eq('unavailable 0 0 -', rt('docker')->{size}->(rt('docker'), ''), 'neither source parses: unavailable, never a guess');
mode('yes');
($out) = proc('docker');
has($out, 'skip: docker size unavailable, skipping action for safety.', 'an unavailable docker size skips the action');
is_eq('', mutate(), 'no builder prune runs on an unavailable size');
fx_reset();

# ---- measurement.sh: docker ------------------------------------------------------------
section('[docker] same-source delta is real; a source change between probes is unavailable');
reset_logs(); mode('yes');
($out) = proc('docker');
has($out, 'docker: observed footprint change: 0.0B (0 bytes)', 'a same-source before/after pair reports a measured delta');
has($out, 'docker reclaimable via the safe verb (5.6GB, 6000000000 bytes)', 'the safe line carries the system df figure');
has($out, 'note: docker reclaimable is an upper bound (not pinned by an active build)', 'the safe-tier estimate note is printed');
has($out, 'docker purge verb (docker builder prune -a) clears the whole unused build cache', 'the purge-scope note replaces a purge figure');
is_eq('6000000000 0', "$CachePrune::Main::SAFE_RECLAIMABLE_BYTES $CachePrune::Main::PURGE_RECLAIMABLE_BYTES", 'docker counts toward the safe tier only');
reset_logs(); $FX{df_fail_after_prune} = 1;
($out) = proc('docker');
has($out, 'docker: observed footprint change: unavailable (docker size source changed between probes: system-df -> buildx-du)', 'system-df before, buildx-du after: the delta is unavailable');
fx_reset();

# ---- actions.sh: docker election ---------------------------------------------------------
section('[docker] election: --yes safe only; --yes --include-purge purge only, never filtered');
reset_logs(); mode('report');
proc('docker');
has(all_log(), 'docker info|', 'the docker preflight runs during report');
has(all_log(), 'docker system df|', 'the docker size parse runs during report');
hasnt(mutate(), 'builder', '--report runs no builder prune');
reset_logs(); mode('yes');
proc('docker');
has(mutate(), 'docker builder prune --force|', '--yes alone runs only the safe docker verb, unfiltered');
hasnt(mutate(), 'builder prune -a', '--yes alone never runs the purge verb');
reset_logs(); mode('yes', 1);
proc('docker');
is_eq('docker builder prune -a --force|', (mutate() =~ /\A(docker builder prune[^|]*\|)/)[0], '--yes --include-purge runs only the docker purge verb');
reset_logs(); mode('yes', 1); $CachePrune::Core::DOCKER_UNTIL = '24h';
proc('docker');
hasnt(mutate(), 'until=', 'DOCKER_UNTIL never adds a --filter to the purge call');
reset_logs(); mode('yes'); $CachePrune::Core::DOCKER_UNTIL = '24h';
proc('docker');
has(mutate(), 'docker builder prune --filter until=24h --force|', 'the safe prune filter reflects --docker-until');
reset_logs(); mode('interactive'); $CONFIRM_YES = 'Prune docker cache?';
proc('docker');
is_eq('Prune docker cache?|', (confirms() =~ /\A([^|]*\|)/)[0], 'interactive docker offers the safe confirm first');
hasnt(confirms(), 'Purge docker', 'interactive docker without --include-purge offers no purge confirm');
is_eq('docker builder prune --force|', (mutate() =~ /\A(docker builder prune[^|]*\|)/)[0], 'interactive docker without --include-purge runs only the safe verb');

section('[partial failure] docker still processes after another runtime fails');
reset_logs(); mode('yes');
CachePrune::Runtime::register_runtime({ name => 'failfirst', detect => sub { 1 }, size => sub { 'available 10 10 x' }, prune => sub { 0 } });
my @saved = @CachePrune::Runtime::ORDER;
@CachePrune::Runtime::ORDER = (rt('failfirst'), rt('docker'));
my ($o2, $e2) = capture(sub { CachePrune::Main::process_runtime($_) for @CachePrune::Runtime::ORDER; });
has($e2, 'failfirst: prune failed', 'the failing runtime warns');
has(mutate(), 'docker builder prune', 'docker still processes after a failure');
is_eq('1', F(), 'the aggregate failure flag is set');
@CachePrune::Runtime::ORDER = @saved;
delete $CachePrune::Runtime::BY_NAME{failfirst};

section('[main] full run smoke with docker present: Total sections');
reset_logs(); %PRESENT = (docker => 1);
($out) = capture(sub { CachePrune::Main::main('--yes') });
has($out, 'Observed footprint change', 'the --yes Total section prints the observed delta line');
has($out, 'Estimated safe-tier reclaimable (upper bound): 5.6GB', 'docker feeds the safe-tier estimate');
($out) = capture(sub { CachePrune::Main::main('--report') });
hasnt($out, 'Observed footprint change', 'the --report Total section prints no delta line');
%PRESENT = (docker => 1, gio => 1);

# ---- docker-residue.sh: classifier ---------------------------------------------------------
section('[docker-residue] classifier over captured JSON');
my $rows = classify_doc(slurp_file("$FIXD/classify-input.json"));
my $class_of = sub { my $ref = shift; join('', map { (split /\t/)[0] } grep { (split /\t/)[1] eq $ref } split /\n/, $rows); };
is_eq('superseded', $class_of->('homelab-cameras:wp2'), 'an older work tag of a live repository (offset timestamps) is superseded');
is_eq('superseded', $class_of->('llama-vulkan:b10121'), 'an older tag of the compose-pinned llama repository is superseded');
is_eq('unreferenced', $class_of->('llama-vulkan:b11429-swap243'), 'a tag newer than its live sibling is unreferenced, never superseded');
is_eq('', $class_of->('llama-vulkan:b10534-swap243'), 'the compose-pinned tag is live');
is_eq('', $class_of->('homelab-cameras:latest'), 'the implied <project>-<service>:latest of a build-only service is live');
is_eq('', $class_of->('searxng/searxng:2026.8.22-9fea41204'), 'a docker.io/-prefixed compose ref matches the unprefixed local tag');
is_eq('', $class_of->('ghcr.io/example/homehub:2026.9.4'), "a profiled service's image is live");
is_eq('', $class_of->('ghcr.io/example/webapp:v0.11.4-slim') . $class_of->('alpine:latest'), 'Dockerfile base refs (incl. implicit :latest) protect their images');
hasnt($rows, "stale\tengine-svc-tts", 'an exited container of a live compose service is not stale');
is_eq('', $class_of->('engine-svc-tts:torch2.11-rocm7.2'), "the image of a live service's exited container is live");
has($rows, "stale\tlegacy_project-old-1\tsha256:prerename0000\t1000\t", "a pre-rename project's exited container is stale, with its writable-layer bytes");
has($rows, "unreferenced\tlegacy_project-legacy-project:latest\tsha256:prerename0000\t384300000\t2026-07-09T00:00:00Z\tlegacy_project-old-1", 'an image held only by a stale container is a candidate naming its blocker');
has($rows, "volume\thomelab_radar-data\t4300000000\t0\tdangling", 'a zero-link volume is flagged dangling');
{
	my $wrapper = File::Basename::dirname($prog) . '/../docker-residue.pl';
	open(my $p, '-|', 'sh', '-c', 'perl "$1" classify < "$2"', 'sh', $wrapper, "$FIXD/classify-input.json") or die;
	local $/; my $cli = <$p>; close $p;
	is_eq("$rows\n", $cli, 'the docker-residue.pl wrapper classify mode prints exactly the module rows');
}

section('[docker-residue] Dockerfile base-ref resolution (the FROM parser, through capture)');
my $DR_ROOT = "$SB/docker-residue-root";
mkdir $DR_ROOT; mkdir "$DR_ROOT/homelab";
{ open(my $h, '>', "$DR_ROOT/homelab/compose.yml") or die; close $h; }
my $build_doc = sub {
	my ($df, $args) = @_;
	local $FX{images} = '[]'; local $FX{containers} = '[]';
	local $FX{compose} = sprintf('{"name":"p","services":{"s":{"build":{"context":"%s","dockerfile":"%s","args":%s}}}}', $FIXD, $df, $args // 'null');
	return capture_doc($DR_ROOT);
};
is_eq('ghcr.io/example/webapp:v0.11.4-slim', field($build_doc->('Dockerfile.overlay'), 'base_refs'), 'ARG default feeds FROM ${ARG}');
is_eq('example/upstream:9', field($build_doc->('Dockerfile.overlay', '{"UPSTREAM":"example/upstream:9"}'), 'base_refs'), 'a compose build arg overrides the ARG default');
is_eq("alpine:latest\ngolang:1.26.7-trixie", field($build_doc->('Dockerfile.multistage'), 'base_refs'), 'stage names and scratch are never image refs; --platform is skipped');
is_eq("Dockerfile unreadable or unresolved FROM: $FIXD/Dockerfile.unresolved", field($build_doc->('Dockerfile.unresolved'), 'image_error'), 'an unresolvable FROM variable fails closed');
is_eq("Dockerfile unreadable or unresolved FROM: $FIXD/Dockerfile.absent", field($build_doc->('Dockerfile.absent'), 'image_error'), 'an unreadable Dockerfile fails closed');
is_eq('null', field($build_doc->('Dockerfile.overlay', '{"GIT_SHA":"${X:-unknown}"}'), 'image_error'), 'an unresolved build arg that no FROM uses does not fail');

section('[docker-residue] capture: compose resolved with every profile, fail closed on error');
reset_logs();
$rows = classify_doc(capture_doc($DR_ROOT));
has(all_log(), '--profile * config --no-interpolate --format json', "compose is resolved uninterpolated with --profile '*'");
hasnt(all_log(), '--project-directory', 'an ordinary compose file gets no --project-directory');
is_eq("superseded\twebapp-overlay:v0.11.3\tsha256:old\t5\t2026-01-01T00:00:00Z\t-", join("\n", grep { !/\Avolume/ } split /\n/, $rows), 'captured compose + Dockerfiles classify end to end');

section('[docker-residue] capture: an unset or empty CACHE_PRUNE_REPO_ROOT runs no compose search');
for my $root (undef, '') {
	reset_logs();
	local $FX{images} = '[]';
	{ local $ENV{CACHE_PRUNE_REPO_ROOT}; $ENV{CACHE_PRUNE_REPO_ROOT} = $root if defined $root; capture_doc(); }
	hasnt(all_log(), 'compose -f', 'no root (' . (defined $root ? 'empty' : 'unset') . '), no default: no compose file is searched or resolved');
}

section('[docker-residue] capture: CACHE_PRUNE_COMPOSE_PROJECT_DIRS pins and the unresolved-variable guard');
my $PIN = "$SB/docker-residue-pin-root";
mkdir $PIN; mkdir "$PIN/stack"; mkdir "$PIN/stack/deploy";
{ open(my $h, '>', "$PIN/stack/deploy/compose.main.yml") or die; close $h; }
{
	local $FX{images} = '[]';
	local $ENV{CACHE_PRUNE_COMPOSE_PROJECT_DIRS} = "malformed-line\nstack/deploy/compose.main.yml=stack";
	reset_logs(); capture_doc($PIN);
	has(all_log(), "compose -f $PIN/stack/deploy/compose.main.yml --project-directory $PIN/stack --profile * config --no-interpolate --format json", 'a listed compose file is pinned with --project-directory <root>/<dir>');
	$ENV{CACHE_PRUNE_COMPOSE_PROJECT_DIRS} = '';
	reset_logs(); capture_doc($PIN);
	hasnt(all_log(), '--project-directory', 'an empty pin list pins nothing');
}
my $json_doc = sub { local $FX{images} = '[]'; local $FX{compose} = $_[0]; return capture_doc($DR_ROOT); };
is_eq("compose config has unresolved variable: $DR_ROOT/homelab/compose.yml", field($json_doc->('{"name":"p","services":{"s":{"image":"foo:${TAG}"}}}'), 'image_error'), 'an unresolved ${VAR} image fails closed');
is_eq("compose config has unresolved variable: $DR_ROOT/homelab/compose.yml", field($json_doc->('{"name":"p","services":{"s":{"image":"foo:$TAG"}}}'), 'image_error'), 'an unresolved unbraced $VAR image fails closed');
is_eq('null', field($json_doc->('{"name":"p","services":{"s":{"image":"foo:a$$b"}}}'), 'image_error'), '$$ is an escape, not a reference');
reset_logs(); $FX{compose_rc} = 1;
$rows = classify_doc(capture_doc($DR_ROOT));
has($rows, "unavailable\timages\tcompose config failed: ", 'a compose-config failure reports the image classes unavailable');
is_eq('', join('', grep { /\A(?:superseded|unreferenced|stale)/ } split /\n/, $rows), 'a compose-config failure yields no candidates');
has($rows, "volume\torphan-vol\t43350000\t0\tdangling", 'volumes still report when the image classes fail closed');
$FX{compose_rc} = 0;

section('[docker-residue] an unparsable created time fails safe (never superseded)');
my $bad = $J->decode('{"images":[{"id":"sha256:live","tags":["webapp-overlay:v0.11.4"],"created":"2026-09-01T00:00:00Z","size":7},{"id":"sha256:old2","tags":["dead:1"],"created":"2026-01-01T00:00:00Z","size":1},{"id":"sha256:liveb","tags":["dead:2"],"created":"garbage","size":1}],"containers":[],"compose":[{"project":"p","services":[{"name":"a","image":"webapp-overlay:v0.11.4","build":false},{"name":"b","image":"dead:2","build":false}]}],"base_refs":[],"volumes":[],"image_error":null,"volume_error":null}');
push @{ $bad->{images} }, { id => 'sha256:badts', tags => ['webapp-overlay:v0.0.1'], created => 'not-a-date', size => 3 };
$rows = classify_doc($J->encode($bad));
$class_of = sub { my $ref = shift; join('', map { (split /\t/)[0] } grep { (split /\t/)[1] eq $ref } split /\n/, $rows); };
is_eq('unreferenced', $class_of->('webapp-overlay:v0.0.1'), 'a candidate with an unparsable created time is unreferenced');
is_eq('unreferenced', $class_of->('dead:1'), "a candidate whose live sibling's time is unparsable is unreferenced");

section('[docker-residue] a large image list (> 128 KiB of JSON) captures in-process');
{
	local $FX{images} = $J->encode([ map { { Id => sprintf('sha256:%064x', $_), RepoTags => ["bulk/image-$_:v1"], Created => '2026-01-01T00:00:00Z', Size => $_ } } 1 .. 2500 ]);
	my $big = capture_doc($DR_ROOT);
	is_eq('1', length($FX{images}) > 131072 ? 1 : 0, 'the fixture image list exceeds 128 KiB');
	is_eq('2500', scalar @{ $J->decode($big)->{images} }, 'every image of an oversized list is captured');
	is_eq('null', field($big, 'image_error'), 'an oversized list is no image_error');
}

# ---- docker-residue.sh: report and election under the docker runtime --------------------
$ENV{CACHE_PRUNE_REPO_ROOT} = $DR_ROOT;
section('[docker-residue] --report under the docker runtime never mutates');
reset_logs(); mode('report');
($out) = proc('docker');
has($out, 'docker superseded images: 5.0B (5 bytes, 1 tags) (safe tier, upper bound: shared layers)', '--report prints the superseded class under docker');
has($out, 'docker volumes: 1 (1 dangling', '--report prints the volumes section');
has($out, 'report-only, no verb', 'volumes say they have no verb');
is_eq('', mutate(), '--report issues no mutating docker command');

$FX{images} = $IMAGES; $FX{containers} = $CONTAINERS; $FX{df_json} = $DF_JSON;
my $banned = '';
sub dr_run { my ($m, $ip) = @_; reset_logs(); mode($m, $ip); my @x = proc('docker'); $banned .= mutate(); return ($x[0] . $x[1]); }
sub residue_mut { return join('', grep { !/\Adocker builder/ } map { "$_|" } @MUTATE); }

section('[docker-residue] --yes removes superseded tags only');
$out = dr_run('yes');
has(mutate(), 'docker builder prune', '--yes still runs docker builder prune');
has(mutate(), 'docker rmi webapp-overlay:v0.11.1|docker rmi webapp-overlay:v0.11.3|', '--yes untags each superseded tag by ref');
hasnt(mutate(), 'docker rm ', '--yes removes no container');
hasnt(mutate(), 'orphan-', '--yes removes no unreferenced image');
has($out, 'skipped: 2 unreferenced images need a per-image interactive confirm', '--yes says why unreferenced images are skipped');
has($out, 'docker images/containers/volumes: observed footprint change 0.0B', 'the residue step prints its own measured footprint line');

section('[docker-residue] --yes --include-purge: stale containers first');
dr_run('yes', 1);
has(mutate(), 'docker builder prune -a --force|docker rm gone-x-1|docker rmi webapp-overlay:v0.11.1|docker rmi webapp-overlay:v0.11.3|', 'builder prune, then stale rm, then superseded rmi');
hasnt(mutate(), 'orphan-', '--yes --include-purge still removes no unreferenced image');

section('[docker-residue] interactive --include-purge: one confirm per unreferenced image');
reset_logs(); mode('interactive', 1); $CONFIRM_YES = 'orphan-b:1';
($out) = proc('docker');
has(confirms(), 'Remove 2 superseded docker image tags (9.0B)?|Remove 1 stale docker containers (gone-x-1)? (purge tier)|Remove unreferenced docker image orphan-a:1 (11.0B)? (purge tier)|Remove unreferenced docker image orphan-b:1 (13.0B)? (purge tier)|', 'superseded, stale, then per-image confirms');
is_eq('docker rmi orphan-b:1|', mutate(), 'a yes on one image and no on another removes exactly that one');
hasnt($out, 'docker: skipped.', 'an acted residue step suppresses the skipped line');
$banned .= mutate();

section('[docker-residue] plain interactive never prompts for stale or unreferenced');
reset_logs(); mode('interactive');
($out) = proc('docker');
hasnt(confirms(), 'stale', 'no stale-container prompt without --include-purge');
hasnt(confirms(), 'unreferenced', 'no unreferenced prompt without --include-purge');
has(confirms(), 'Remove 2 superseded docker image tags', 'plain interactive offers the superseded class');
has($out, 'docker: skipped.', 'declining everything still reports skipped');

section('[docker-residue] a per-item conflict warns and the next item still runs');
$FX{rm_fail} = 'webapp-overlay:v0.11.1';
$out = dr_run('yes');
has($out, 'WARNING: docker: could not remove image webapp-overlay:v0.11.1 (left in place)', 'the conflicting item is warned about');
has(mutate(), 'docker rmi webapp-overlay:v0.11.3|', 'the next superseded tag is still removed');
has($out, 'superseded tags removed 1, failed 1', 'the summary counts removed and failed');
is_eq('0', F(), 'a per-item failure is a warning, not a run failure');
$FX{rm_fail} = '';

section('[docker-residue] an images-unavailable capture elects nothing');
$FX{compose_rc} = 1;
$out = dr_run('yes', 1);
is_eq('docker builder prune -a --force|', mutate(), 'only the build-cache purge verb runs when images are unavailable');
has($out, 'docker residue: nothing elected (images unavailable: compose config failed', 'says why nothing was elected');
$FX{compose_rc} = 0;

section('[docker-residue] anonymous volumes: capture, classification and report');
$FX{volumes} = $ANON_VOLS;
$rows = classify_doc(capture_doc());
is_eq("anonvolume\tanon-b\t3000000\nanonvolume\tanon-a\t2000000", join("\n", grep { /\Aanonvolume/ } split /\n/, $rows), 'only zero-link volumes carrying the anonymous label key (first or not) are anonvolume rows');
has($rows, "volume\tnamed-d\t5000000\t0\tdangling", 'a named dangling volume keeps its volume row');
has($rows, "volume\tanon-linked\t1000000\t1\tlinked", 'a linked anonymous volume is a plain linked volume row');
my ($rep) = capture(sub { CachePrune::Runtime::docker::report(split /\n/, $rows) });
has($rep, 'docker anonymous volumes: 2 dangling, 4.8MB (5000000 bytes) (purge tier, removed by name)', 'the report prints the anonymous volumes line');
has($rep, 'docker volumes: 5 (4 dangling', 'the volumes line still counts every volume');
has($rep, '2 named dangling: report-only, no verb', 'named dangling volumes say they are report-only');
hasnt($rep, 'never removes volumes', 'the volumes line no longer claims no volume is ever removed');
($rep) = capture(sub { CachePrune::Runtime::docker::report("unavailable\tvolumes\tdocker system df -v failed") });
has($rep, 'docker anonymous volumes: unavailable (docker system df -v failed)', 'volumes unavailable: the anonymous line claims no count');

section('[docker-residue] anonymous volumes: election and removal');
dr_run('yes');
hasnt(mutate(), 'volume rm', 'plain --yes never removes a volume');
reset_logs(); mode('interactive');
proc('docker');
hasnt(confirms(), 'anonymous', 'plain interactive never offers the volume step');
hasnt(mutate(), 'volume rm', 'plain interactive never removes a volume');
$out = dr_run('yes', 1);
has(mutate(), 'docker rm gone-x-1|docker volume rm anon-b|docker volume rm anon-a|docker rmi ', '--yes --include-purge: stale rm, then volume rm per anonymous dangling name, then rmi');
is_eq('2', scalar(() = mutate() =~ /volume rm /g), 'exactly the anonymous dangling set is removed');
hasnt(mutate(), 'named-d', 'a named dangling volume is never passed to volume rm');
has($out, 'anonymous volumes removed 2, failed 0', 'the summary counts volumes');
reset_logs(); mode('interactive', 1); $CONFIRM_YES = 'anonymous dangling docker volumes';
proc('docker');
has(confirms(), 'Remove 2 anonymous dangling docker volumes (4.8MB)? (purge tier)', 'interactive --include-purge: one confirm naming count and size');
is_eq('docker volume rm anon-b|docker volume rm anon-a|', mutate(), 'a yes on the volume confirm removes exactly the anonymous set');
$banned .= mutate();

section("[docker-residue] a volume orphaned by this run's stale removal waits");
$FX{volumes_after_rm} = '[{"Name":"anon-a","Size":"2MB","Links":"0","Labels":"com.docker.volume.anonymous="},{"Name":"anon-linked","Size":"1MB","Links":"0","Labels":"com.docker.volume.anonymous="}]';
dr_run('yes', 1);
has(mutate(), 'docker volume rm anon-a|', 'a volume dangling before and after is removed');
hasnt(mutate(), 'anon-linked', 'a volume dangling only after the stale rm is not removed this run');
hasnt(mutate(), 'anon-b', 'a volume gone from the fresh capture is not removed');
$FX{volumes_after_rm} = '';

section('[docker-residue] a per-item volume rm failure warns and the run continues');
$FX{rm_fail} = 'anon-b';
$out = dr_run('yes', 1);
has($out, 'could not remove volume anon-b', 'the failing volume is warned about');
has(mutate(), 'docker volume rm anon-a|', 'the next volume is still removed');
has($out, 'anonymous volumes removed 1, failed 1', 'the summary counts the failure');
$FX{rm_fail} = '';

section('[docker-residue] volumes unavailable elects no volume');
$FX{volumes_rc} = 1;
dr_run('yes', 1);
hasnt(mutate(), 'volume rm', 'no volume is removed when the volume capture fails');
$FX{volumes_rc} = 0;

section('[docker-residue] the footprint line includes volumes');
$FX{df_json} = qq({"Type":"Images","Size":"40B"}\n{"Type":"Containers","Size":"1kB"});
$out = dr_run('yes', 1);
has($out, 'docker images/containers/volumes: observed footprint change unavailable', 'a missing Local Volumes row makes the footprint unavailable');
$FX{df_json} = $DF_JSON;

section('[docker-residue] banned verbs never appear in any mode');
my $hit = join(';', grep { index($banned, $_) >= 0 } ('system prune', 'image prune', 'volume prune', 'volume rm -f', 'volume rm --force', 'rmi -f', 'rmi --force', 'rm -f', 'rm --force'));
is_eq('', $hit, 'no prune/forced verb across every mode');
is_eq('', join(' ', grep { !/\Avolume rm (?:anon-a|anon-b)\z/ } $banned =~ /(volume rm [^|]*)/g), 'every volume rm names an elected anonymous volume');

section('[docker-residue] the residue delta is before minus after (a freed footprint prints positive)');
$FX{volumes} = '[]'; $FX{images} = '[]';
$FX{containers} = '[{"Name":"/gone-x-1","Id":"c1","Image":"sha256:zz","Config":{"Image":"z:1","Labels":{}},"State":{"Status":"exited"},"Created":"2026-02-02T00:00:00Z"}]';
for my $c (['1000 400', 'docker images/containers/volumes: observed footprint change 600.0B (600 bytes)', '1000 -> 400 reports 600 bytes freed, positive'],
	['fail 400', 'docker images/containers/volumes: observed footprint change unavailable (docker system df --format json reading failed)', 'a failed pre-probe prints the unavailable line'],
	['1000 fail', 'docker images/containers/volumes: observed footprint change unavailable (docker system df --format json reading failed)', 'a failed post-probe prints the unavailable line']) {
	reset_logs(); mode('yes', 1); $FX{fp} = [ split / /, $c->[0] ];
	my ($o, undef, $acted) = capture(sub { CachePrune::Runtime::docker::residue(rt('docker')) });
	has($o, $c->[1], $c->[2]);
	is_eq('1', $acted ? 1 : 0, "an acting residue step returns true ($c->[0])");
}
$FX{fp} = undef;
fx_reset();

section('[missing tool] docker residue: no JSON::PP on host is named in the report and the election');
{
	local $CachePrune::DockerResidue::HAVE_JSON = 0;
	reset_logs(); mode('yes');
	my ($o) = capture(sub { CachePrune::Runtime::docker::detail(rt('docker')) });
	is_eq("docker image/container/volume residue: unavailable (no JSON::PP on host)\n", $o, 'the residue detail line names the missing JSON::PP');
	($o) = capture(sub { CachePrune::Runtime::docker::residue(rt('docker')) });
	is_eq("docker residue: nothing elected (no JSON::PP on host)\n", $o, 'the residue election names the missing JSON::PP');
	is_eq('', mutate(), 'nothing is removed without JSON::PP');
}
delete $ENV{CACHE_PRUNE_REPO_ROOT};

# ---- trash.sh -------------------------------------------------------------------------
my $TR = "$SB/trash-fixture";
sub trash_fixture {
	system('rm', '-rf', $TR);
	mkdir $TR; mkdir "$TR/files"; mkdir "$TR/files/dir1"; mkdir "$TR/info";
	my $mk = sub { open(my $h, '>', $_[0]) or die; print $h "\0" x $_[1]; close $h; };
	$mk->("$TR/files/a.bin", 4096); $mk->("$TR/files/dir1/b.bin", 8192);
	$mk->("$TR/info/a.bin.trashinfo", 100); $mk->("$TR/info/dir1.trashinfo", 100);
}
trash_fixture();
$ENV{CACHE_PRUNE_TRASH_DIR} = $TR;
my $texp = CachePrune::Adapters::path_du_bytes("$TR/files") + CachePrune::Adapters::path_du_bytes("$TR/info");

section('[trash] registry membership: purge only, interactive-only');
is_eq('purge', join(' ', grep { rt('trash')->{$_} } qw(prune purge cache_dir)), 'trash carries only the purge verb');
has(rt('trash')->{interactive_only}, 'never emptied under --yes', 'trash is interactive-only');

section('[trash detect] gio and the trash dir must both exist');
is_eq('1', rt('trash')->{detect}->(rt('trash')), 'gio plus the fixture dir is detected');
{ local $ENV{CACHE_PRUNE_GIO} = "$SB/no-such-gio"; is_eq('0', rt('trash')->{detect}->(rt('trash')), 'an unresolvable gio command is not detected');
	reset_logs(); my ($o, undef, $r) = proc('trash');
	has($o, 'skip: trash: no no-such-gio on host', 'a missing gio command is named by its basename');
	is_eq('1 0', ($r ? 1 : 0) . ' ' . F(), 'a missing gio is not a failure'); }
{ local $ENV{CACHE_PRUNE_TRASH_DIR} = "$SB/absent-trash"; is_eq('0', rt('trash')->{detect}->(rt('trash')), 'an absent trash dir is not detected');
	my ($o) = proc('trash');
	has($o, "skip: trash: trash dir $SB/absent-trash absent", 'an absent trash dir keeps its own reason'); }
{ local $ENV{CACHE_PRUNE_TRASH_DIR} = ''; local $ENV{XDG_DATA_HOME} = "$SB/xdg";
	is_eq("$SB/xdg/Trash", CachePrune::Runtime::trash::trash_dir(), 'the default dir is ${XDG_DATA_HOME}/Trash');
	delete $ENV{XDG_DATA_HOME};
	is_eq("$SB/home/.local/share/Trash", CachePrune::Runtime::trash::trash_dir(), 'without XDG_DATA_HOME it is $HOME/.local/share/Trash'); }

section('[trash --report] files/ + info/ (+ expunged/) sized, nothing emptied');
is_eq("available $texp $texp trash", rt('trash')->{size}->(rt('trash'), ''), 'size counts files/ + info/, all reclaimable');
reset_logs(); mode('report');
($out) = proc('trash');
has($out, 'trash: 2 items in files/', 'detail counts the items in files/');
has($out, 'emptied only after an interactive confirm, never under --yes', 'the reclaimable line states the interactive-only gate');
has($out, 'note: gio trash --empty also empties per-mount .Trash-<uid> dirs', 'detail names the unsized per-mount trash');
is_eq('', mutate(), '--report never invokes gio');
is_eq('1', -f "$TR/files/a.bin" ? 1 : 0, '--report leaves the fixture intact');
mkdir "$TR/expunged";
{ open(my $h, '>', "$TR/expunged/x") or die; print $h "\0" x 500; close $h; }
my $texp2 = $texp + CachePrune::Adapters::path_du_bytes("$TR/expunged");
is_eq("available $texp2 $texp2 trash", rt('trash')->{size}->(rt('trash'), ''), 'expunged/ counts when present');
trash_fixture();

for my $ip (0, 1) {
	section("[trash --yes include-purge=$ip] never emptied, skip note, not a failure");
	reset_logs(); mode('yes', $ip); $CONFIRM_YES = 'Empty trash';
	my ($o, undef, $r) = proc('trash');
	is_eq('', mutate(), "--yes (include-purge=$ip) never invokes gio");
	has($o, 'skipped: trash needs an interactive confirm', "--yes (include-purge=$ip) prints the skip note");
	is_eq('1 0', ($r ? 1 : 0) . ' ' . F(), "--yes (include-purge=$ip) skip is no failure");
	has($o, 'trash: skipped.', "--yes (include-purge=$ip) is no action");
	hasnt($o, 'trash: observed footprint change', "--yes (include-purge=$ip) prints no delta line");
}

section('[trash interactive] the one confirm gates gio trash --empty');
reset_logs(); mode('interactive');
proc('trash');
is_eq('', mutate(), 'a declined confirm never invokes gio');
reset_logs(); mode('interactive'); $CONFIRM_YES = 'Empty trash';
($out) = proc('trash');
is_eq('gio trash --empty|', mutate(), 'an accepted confirm invokes gio with exactly trash --empty');
has(confirms(), 'Empty trash (' . CachePrune::Measurement::human_bytes($texp) . ", $texp bytes of user-deleted data, not a cache)? (destructive, via gio trash --empty)", 'the confirm names the size and that it is user-deleted data');
has($out, 'trash: observed footprint change: ', 'an accepted purge prints a delta line');
is_eq('1', -f "$TR/files/a.bin" ? 1 : 0, 'the tool itself never removes a trash file (gio does)');

section('[trash interactive] a failing gio is a verb failure');
reset_logs(); mode('interactive'); $CONFIRM_YES = 'Empty trash'; $FX{gio_rc} = 3;
($out, $err) = proc('trash');
has($err, 'trash: prune failed', 'a non-zero gio exit is reported as a failed verb');
is_eq('1', F(), 'a non-zero gio exit sets FAILED');
$FX{gio_rc} = 0;
{ local $ENV{CACHE_PRUNE_GIO} = "$SB/bin/gio"; $PRESENT{"$SB/bin/gio"} = 1;
	reset_logs(); mode('interactive'); $CONFIRM_YES = 'Empty trash';
	proc('trash');
	is_eq('gio trash --empty|', mutate(), 'CACHE_PRUNE_GIO names the gio that runs'); }

printf "\nUNIT %d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
