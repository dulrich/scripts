#!/usr/bin/perl
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# In-process unit cases for util/cache-prune/perl/, run by ./run.sh: `perl unit.pl <cache-prune.pl>
# <sandbox>`. The entrypoint is loaded with `require` (main does not run); the command seam
# (cmd_capture/cmd_run/have_cmd) and confirm are replaced with fakes that log like the bash
# suite's doubles. Only rm, mktemp, git and du reach the real host, always inside <sandbox>.
use strict;
use warnings;
no warnings qw(redefine once);
use Cwd ();
use Fcntl qw(O_RDWR O_CREAT LOCK_EX LOCK_NB);
use File::Basename ();
BEGIN { unshift @INC, File::Basename::dirname(Cwd::realpath($ARGV[0])) if @ARGV && -e $ARGV[0]; }

my ($prog, $SB) = @ARGV;
die "usage: unit.pl <cache-prune.pl> <sandbox>\n" unless defined $prog && defined $SB && -d $SB;
$SB = Cwd::realpath($SB);
$prog = Cwd::realpath($prog);
mkdir "$SB/empty-fleet";
$ENV{CACHE_PRUNE_FLEET_DIR} = "$SB/empty-fleet";
$ENV{HOME} = "$SB/home";
mkdir $ENV{HOME};
require $prog;
main::cache_prune_load();

my ($pass, $fail) = (0, 0);
sub ok { $pass++; print "  ok   - $_[0]\n"; }
sub bad { $fail++; print "  FAIL - $_[0]\n"; }
sub is_eq { my ($exp, $got, $label) = @_; $got = '<undef>' unless defined $got; $exp eq $got ? ok($label) : bad("$label (expected <$exp>, got <$got>)"); }
sub truthy { my ($label, $v) = @_; $v ? ok($label) : bad($label); }
sub falsy { my ($label, $v) = @_; $v ? bad($label) : ok($label); }
sub has { my ($hay, $needle, $label) = @_; index($hay, $needle) >= 0 ? ok($label) : bad("$label (expected <$needle> in <$hay>)"); }
sub hasnt { my ($hay, $needle, $label) = @_; index($hay, $needle) < 0 ? ok($label) : bad("$label (did not expect <$needle> in <$hay>)"); }
sub section { print "$_[0]\n"; }

# capture(sub) -> (stdout, stderr): both handles go to sandbox files for the duration.
my $capn = 0;
sub capture {
	my ($code) = @_;
	$capn++;
	my ($fo, $fe) = ("$SB/cap$capn.out", "$SB/cap$capn.err");
	STDOUT->flush; STDERR->flush;
	open(my $so, '>&', \*STDOUT) or die; open(my $se, '>&', \*STDERR) or die;
	open(STDOUT, '>', $fo) or die; open(STDERR, '>', $fe) or die;
	my @r = $code->();
	STDOUT->flush; STDERR->flush;
	open(STDOUT, '>&', $so) or die; open(STDERR, '>&', $se) or die;
	my $slurp = sub { open(my $h, '<', $_[0]) or return ''; local $/; my $c = <$h>; return $c // ''; };
	return ($slurp->($fo), $slurp->($fe), @r);
}

# ---- fakes ----------------------------------------------------------------------
our (@ALL, @MUTATE, @CONFIRM_LOG);
our $CONFIRM_RESULT = 0;
our %RESULT;           # 'uv cache prune' => exit status
our $NPM_MODE = 'ok';  # ok | undefined | error
our %PRESENT;
my %DIR = (uv => "$SB/uv-cache", npm => "$SB/npm-cache", pip => "$SB/pip-cache");
mkdir $_ for values %DIR;
$ENV{BUN_INSTALL} = "$SB/bun-install";
$ENV{CARGO_HOME} = "$SB/cargo-home";
my $real_capture = \&CachePrune::Core::cmd_capture;
my $real_run = \&CachePrune::Core::cmd_run;
my %REAL = map { $_ => 1 } qw(rm mktemp git du);
sub fake_cmd {
	my ($cap, @c) = @_;
	my $n = shift @c;
	my $line = "$n @c";
	push @ALL, $line;
	if ($line =~ /\A(?:uv cache (?:prune|clean)|npm cache (?:verify|clean --force)|pip cache purge|bun pm cache rm)\z/) {
		push @MUTATE, $line;
		return ('', $RESULT{$line} // 0);
	}
	return ($DIR{$n}, 0) if $line eq "$n cache dir" && $DIR{$n};
	if ($line eq 'npm config get cache') {
		return ('', 1) if $NPM_MODE eq 'error';
		return ('undefined', 0) if $NPM_MODE eq 'undefined';
		return ($DIR{npm}, 0);
	}
	return ('', 0);
}
*CachePrune::Core::cmd_capture = sub {
	my @c = @_;
	my $o = ref $c[0] eq 'HASH' ? shift @c : undef;
	return $real_capture->(@_) if $REAL{ $c[0] };
	return fake_cmd(1, @c);
};
*CachePrune::Core::cmd_run = sub {
	my @c = @_;
	my $o = ref $c[0] eq 'HASH' ? shift @c : undef;
	return $real_run->(@_) if $REAL{ $c[0] };
	return (fake_cmd(0, @c))[1];
};
*CachePrune::Core::have_cmd = sub { return $PRESENT{ $_[0] } ? 1 : 0; };
*CachePrune::Core::confirm = sub { push @CONFIRM_LOG, $_[0]; return $CONFIRM_RESULT; };

sub all_present { %PRESENT = map { $_ => 1 } qw(uv npm pip bun cargo); }
sub all_absent { %PRESENT = (); }
sub reset_logs {
	@ALL = (); @MUTATE = (); @CONFIRM_LOG = (); $CONFIRM_RESULT = 1; %RESULT = (); $NPM_MODE = 'ok';
	$CachePrune::Core::FAILED = 0;
	CachePrune::Main::reset_totals();
}
sub mode { ($CachePrune::Core::MODE, $CachePrune::Core::INCLUDE_PURGE) = @_; $CachePrune::Core::INCLUDE_PURGE //= 0; }
sub rt { return $CachePrune::Runtime::BY_NAME{ $_[0] } // die "no runtime $_[0]\n"; }
sub mutate { return join('', map { "$_|" } @MUTATE); }
sub confirms { return join('', map { "$_|" } @CONFIRM_LOG); }
sub all_log { return join('', map { "$_|" } @ALL); }
# with_size(name, sub, code): run code with the runtime's size hook replaced.
sub with_size { my ($name, $size, $code) = @_; my $r = rt($name); my $orig = $r->{size}; $r->{size} = $size; my @x = $code->(); $r->{size} = $orig; return @x; }
sub queue { my @q = @_; return sub { return shift @q; }; }
sub proc { my ($name) = @_; return capture(sub { CachePrune::Main::process_runtime(rt($name)) }); }
sub proc_all { my $o = ''; my $e = ''; for my $r (@CachePrune::Runtime::ORDER) { my ($a, $b) = capture(sub { CachePrune::Main::process_runtime($r) }); $o .= $a; $e .= $b; } return ($o, $e); }
sub delta_line { my ($out) = @_; return join("\n", grep { /observed footprint change/ } split /\n/, $out); }
sub F { return $CachePrune::Core::FAILED; }
sub T { no strict 'refs'; return ${"CachePrune::Main::$_[0]"}; }

use CachePrune::Measurement qw(probe_available probe_unavailable probe_is_valid probe_is_available probe_compare human_bytes human_bytes_signed);

# ---- registry -----------------------------------------------------------------
section('[registry] core order and hook membership');
is_eq('uv npm pip bun cargo', join(' ', map { $_->{name} } @CachePrune::Runtime::ORDER), 'core runtimes register in the bash order (docker/trash arrive in WP-9)');
for my $n (qw(uv npm)) { truthy("$n has a safe verb (prune)", rt($n)->{prune}); truthy("$n has a purge verb", rt($n)->{purge}); }
for my $n (qw(pip bun cargo)) { falsy("$n has no safe verb -- purge-only", rt($n)->{prune}); truthy("$n has a purge verb (its only verb)", rt($n)->{purge}); }

# ---- adapters.sh --------------------------------------------------------------
section('[detect] graceful skip when a runtime is absent');
all_absent(); reset_logs(); mode('report');
my ($out, $err) = proc('uv');
is_eq('', all_log(), 'no external calls made for an absent runtime');
is_eq('0', F(), 'an absent runtime is a skip, not a failure');

section('[cache-dir resolver] unresolvable result (exit 2) is a skip, not a failure');
all_present(); reset_logs(); mode('report'); $NPM_MODE = 'undefined';
($out, $err) = proc('npm');
has($out . $err, 'skip: npm cache location unresolved', 'an unresolvable npm cache dir prints the skip message');
is_eq('', mutate(), 'an unresolvable npm cache dir performs no mutation');
is_eq('0', F(), 'an unresolvable npm cache dir (exit 2) does not set FAILED');

section('[cache-dir resolver] a hard resolver failure (exit 1) is a real failure');
all_present(); reset_logs(); mode('report'); $NPM_MODE = 'error';
($out, $err) = proc('npm');
has($out . $err, 'WARNING: npm: failed to resolve cache location', 'a hard npm resolver failure warns');
is_eq('1', F(), 'a hard npm resolver failure (exit 1) sets FAILED');

section('[census] inode-complete link census');
sub mkfile { my ($p, $n) = @_; open(my $h, '>', $p) or die "$p: $!"; print $h "\0" x $n; close $h; }
sub census { return join(' ', CachePrune::Adapters::dir_census_bytes($_[0])); }
mkdir "$SB/census-plain"; mkfile("$SB/census-plain/plain.bin", 111);
is_eq('111 111', census("$SB/census-plain"), 'a plain unlinked file counts toward both total and reclaimable');
mkdir "$SB/census-shared"; mkfile("$SB/census-shared/a.bin", 222); link "$SB/census-shared/a.bin", "$SB/census-shared/b.bin";
is_eq('222 222', census("$SB/census-shared"), 'a file hardlinked twice inside the tree counts once toward total and is fully reclaimable');
mkdir "$SB/census-external"; mkdir "$SB/census-external-outside"; mkfile("$SB/census-external/inside.bin", 333);
link "$SB/census-external/inside.bin", "$SB/census-external-outside/outside.bin";
is_eq('333 0', census("$SB/census-external"), 'a file with an additional link outside the tree counts toward total but contributes zero to reclaimable');
mkdir "$SB/census-empty";
is_eq('0 0', census("$SB/census-empty"), 'an empty directory returns 0 0');
is_eq('0 0', census("$SB/census-does-not-exist"), 'a nonexistent path returns 0 0');
mkdir "$SB/census-nested"; mkdir "$SB/census-nested/d"; mkfile("$SB/census-nested/d/f", 50); symlink "$SB/census-plain", "$SB/census-nested/link";
is_eq('50 50', census("$SB/census-nested"), 'nested files count and a symlinked directory is never followed');

section('[generic_size] the census reaches the registry as a probe record, source and all');
is_eq('available 111 111 census', CachePrune::Adapters::generic_size(undef, "$SB/census-plain"), 'the directory adapter wraps the census pair in a record naming census as its source');
is_eq('available 333 0 census', CachePrune::Adapters::generic_size(undef, "$SB/census-external"), 'the record keeps total and reclaimable distinct and in the documented field order');
is_eq('available 0 0 census', CachePrune::Adapters::generic_size(undef, "$SB/census-does-not-exist"), 'a nonexistent cache directory is an available zero measurement, not an unavailable one');
truthy('every directory-backed runtime therefore measures with one comparable source', probe_is_available(CachePrune::Adapters::generic_size(undef, "$SB/census-empty")));
is_eq(CachePrune::Adapters::path_du_bytes("$SB/census-plain") > 0 ? 'positive' : 'zero', 'positive', 'path_du_bytes sizes a path with du -sb');
is_eq('0', CachePrune::Adapters::path_du_bytes("$SB/census-does-not-exist"), 'path_du_bytes reads an unmeasurable path as 0');

# ---- measurement.sh -----------------------------------------------------------
section('[probe record] the transport carries provenance or is not a record');
is_eq('available 1000 900 system-df', probe_available(1000, 900, 'system-df'), 'probe_available emits <status> <total> <reclaimable> <source> in that fixed order');
is_eq('unavailable 0 0 -', probe_unavailable(), 'probe_unavailable emits the canonical unavailable record');
is_eq('unavailable 0 0 -', probe_available(1000, 900, ''), 'an empty source identity yields an unavailable record, never an anonymous available one');
is_eq('unavailable 0 0 -', probe_available(1000, 900, 'two words'), 'a source identity containing whitespace is rejected the same way');

section('[probe record] validation rejects every non-record, including the retired bare pair');
truthy('an available record validates', probe_is_valid('available 1000 900 system-df'));
truthy('the unavailable record validates', probe_is_valid('unavailable 0 0 -'));
falsy('the retired bare <total> <reclaimable> pair is not a record', probe_is_valid('1000 900'));
falsy("a bare 'unavailable' word is not a record", probe_is_valid('unavailable'));
falsy('an available record missing its source is not a record', probe_is_valid('available 1000 900'));
falsy('an empty probe result is not a record', probe_is_valid(''));
falsy('a non-numeric byte field is not a record', probe_is_valid('available abc def census'));
truthy('probe_is_available accepts an available record', probe_is_available('available 1 2 census'));
falsy('probe_is_available rejects an unavailable record', probe_is_available('unavailable 0 0 -'));
falsy('probe_is_available rejects junk', probe_is_available('garbage'));

section('[probe_compare] one helper owns eligibility and signed subtraction');
is_eq('available 200000', probe_compare('uv', 'available 500000 100000 census', 'available 300000 100000 census'), 'two available records from the same source subtract to a signed delta');
is_eq('available 0', probe_compare('uv', 'available 500000 1 census', 'available 500000 1 census'), 'an unchanged cache compares to an explicit zero, not to nothing');
is_eq('available -200000', probe_compare('uv', 'available 500000 1 census', 'available 700000 1 census'), 'a cache that grew compares to a negative delta, reported as observed');
is_eq('unavailable docker size source changed between probes: system-df -> buildx-du', probe_compare('docker', 'available 1000 900 system-df', 'available 400 300 buildx-du'), 'a changed source is ineligible, and the reason names both sources');
is_eq('unavailable npm size source changed between probes: census -> other', probe_compare('npm', 'available 1000 900 census', 'available 400 300 other'), 'the source-match rule is not docker-specific -- it holds for every runtime');
is_eq('unavailable the post-action size probe failed', probe_compare('uv', 'available 1000 900 census', 'unavailable 0 0 -'), 'an unavailable after-record is ineligible');
is_eq('unavailable the post-action size probe failed', probe_compare('uv', 'available 1000 900 census', ''), 'a missing after-record is ineligible');
is_eq('unavailable the post-action size probe failed', probe_compare('uv', 'available 1000 900 census', '400 300'), 'a malformed after-record (a bare pair) is ineligible');
is_eq('unavailable the pre-action size probe failed', probe_compare('uv', 'unavailable 0 0 -', 'available 400 300 census'), 'an unavailable before-record is ineligible');
is_eq('unavailable the pre-action size probe failed', probe_compare('uv', 'unavailable 0 0 -', 'garbage'), "probe_compare answers 'not comparable' rather than failing");

section('[human_bytes] rendering');
is_eq('0.0B', human_bytes(0), 'zero renders 0.0B');
is_eq('1023.0B', human_bytes(1023), 'below 1024 stays in bytes');
is_eq('1.0KB', human_bytes(1024), '1024 is 1.0KB');
is_eq('4.3GB', human_bytes(4638000000), 'GB with one decimal, 1024 steps');
is_eq('-4.7GB', human_bytes_signed(-5000000000), 'a large negative converts units with the sign reattached');
is_eq('-200.0B', human_bytes_signed(-200), 'a small negative stays in bytes');

section('[source identity] a fake runtime whose source changes between probes yields an unavailable delta');
my %calls;
my $fake = CachePrune::Runtime::register_runtime({
	name => 'srcfake', detect => sub { 1 },
	size => queue('available 1000 900 system-df', 'available 400 300 buildx-du'),
	prune => sub { push @MUTATE, 'MOCK srcfake prune'; 1 },
});
reset_logs(); mode('yes');
($out, $err) = proc('srcfake');
my $dl = delta_line($out);
has(mutate(), 'MOCK srcfake prune', 'the mocked action did run, so there really was something to measure around');
has($dl, 'unavailable', 'a cross-source pair reports the delta as unavailable');
has($dl, 'srcfake size source changed between probes: system-df -> buildx-du', 'the unavailable delta names both sources -- provenance travels in the record');
hasnt($dl, '600', 'the cross-source subtraction 1000 - 400 is never reported as a measurement');
is_eq('0', T('DELTA_BYTES'), 'an ineligible pair contributes exactly nothing to the grand-total delta');
is_eq('0', F(), 'an unmeasurable delta is not a failure -- the action itself succeeded');
@CachePrune::Runtime::ORDER = grep { $_->{name} ne 'srcfake' } @CachePrune::Runtime::ORDER;
delete $CachePrune::Runtime::BY_NAME{srcfake};

section('[contract guard] a malformed (non-record) probe result is a failure, not a silent 0');
all_present(); reset_logs(); mode('yes');
(undef, $err) = with_size('uv', sub { '12345' }, sub { proc('uv') });
has($err, 'WARNING: uv:', 'a single-value probe result (the retired bare-pair transport) warns');
is_eq('1', F(), 'a single-value probe result sets FAILED, the same path a hard probe failure takes');
is_eq('0', T('PURGE_RECLAIMABLE_BYTES'), 'a malformed probe never silently contributes to the purge-tier reclaimable total');
is_eq('0', T('SAFE_RECLAIMABLE_BYTES'), 'a malformed probe never silently contributes to the safe-tier reclaimable total');
is_eq('0', T('TOTAL_BYTES'), 'a malformed probe never silently contributes to the footprint total');
reset_logs();
with_size('uv', sub { 'abc def' }, sub { proc('uv') });
is_eq('1', F(), 'a non-numeric probe pair is also treated as a probe failure');
is_eq('0', T('PURGE_RECLAIMABLE_BYTES'), 'non-numeric junk never silently contributes to the purge-tier reclaimable total');
reset_logs();
(undef, $err) = with_size('uv', sub { undef }, sub { proc('uv') });
has($err, 'WARNING: uv: failed to determine cache size', 'a size hook returning undef is a probe failure');
is_eq('1', F(), 'a failed probe sets FAILED');

section('[measure_runtime] a hook that returns nothing lands on the malformed path');
my @m = with_size('uv', sub { '' }, sub { CachePrune::Main::measure_runtime(rt('uv'), $SB) });
is_eq('2', $m[0], 'an adapter that leaves no record lands on the malformed (status 2) path');
is_eq('1', scalar(@m), 'no record is handed back');
reset_logs();
with_size('uv', sub { return; }, sub { proc('uv') });
is_eq('1', F(), 'process_runtime fails closed on an adapter that returns nothing');

section('[process_runtime] prints both figures; footprint and purge-tier totals accumulate independently');
all_present(); reset_logs(); mode('report');
($out) = with_size('uv', sub { 'available 500 0 census' }, sub { proc('uv') });
has($out, '500.0B total (500 bytes)', 'process_runtime prints the total figure');
has($out, 'reclaimable via the purge verb (0.0B, 0 bytes)', 'process_runtime prints the purge-tier reclaimable figure, labelled with its verb');
is_eq('500', T('TOTAL_BYTES'), 'a fully-shared runtime still advances the footprint total');
is_eq('0', T('PURGE_RECLAIMABLE_BYTES'), 'a fully-shared runtime does not advance the purge-tier reclaimable total');
is_eq('0', T('SAFE_RECLAIMABLE_BYTES'), "uv's reclaimable bytes never touch the safe-tier total");

section('[process_runtime] the unavailable path still bypasses both accumulators');
all_present(); reset_logs(); mode('report');
($CachePrune::Main::TOTAL_BYTES, $CachePrune::Main::SAFE_RECLAIMABLE_BYTES, $CachePrune::Main::PURGE_RECLAIMABLE_BYTES) = (12345, 2222, 6789);
($out) = with_size('uv', sub { probe_unavailable() }, sub { proc('uv') });
is_eq('12345', T('TOTAL_BYTES'), 'an unavailable size probe leaves the footprint total untouched');
is_eq('2222', T('SAFE_RECLAIMABLE_BYTES'), 'an unavailable size probe leaves the safe-tier reclaimable total untouched');
is_eq('6789', T('PURGE_RECLAIMABLE_BYTES'), 'an unavailable size probe leaves the purge-tier reclaimable total untouched');
is_eq("\n==== uv ====\nuv cache size: unavailable\nskip: uv size unavailable, skipping action for safety.\n", $out, 'an unavailable size prints the unavailable line and the safety skip');

section('[cargo] reclaimable is registry/src bytes, routed to the purge tier');
all_present(); reset_logs(); mode('report');
my $CH = $ENV{CARGO_HOME};
system('rm', '-rf', $CH);
system('mkdir', '-p', "$CH/registry/src/i/a", "$CH/registry/cache/i");
mkfile("$CH/registry/src/i/a/f", 3000); mkfile("$CH/registry/cache/i/c.crate", 5000);
is_eq('available 8000 3000 census', rt('cargo')->{size}->(rt('cargo'), "$CH/registry"), 'cargo size: total is whole registry/, reclaimable is registry/src bytes');
($out) = proc('cargo');
is_eq('8000', T('TOTAL_BYTES'), "cargo's bytes count toward total footprint");
is_eq('0', T('SAFE_RECLAIMABLE_BYTES'), "cargo's bytes never reach the safe-tier reclaimable total");
is_eq('3000', T('PURGE_RECLAIMABLE_BYTES'), "cargo's registry/src bytes reach the purge-tier reclaimable total");
has($out, 'cargo reclaimable via the purge verb', 'cargo prints a purge-verb reclaimable line');

sub delta_case {
	my ($label, $q, %o) = @_;
	all_present(); reset_logs(); mode($o{mode} // 'yes', $o{purge} // 0);
	$RESULT{'uv cache prune'} = $o{prune_rc} if defined $o{prune_rc};
	$CONFIRM_RESULT = $o{confirm} if defined $o{confirm};
	section($label);
	my ($o2, $e2, $rv) = with_size('uv', queue(@$q), sub { proc('uv') });
	return ($o2, $e2, $rv);
}
my $rv;
($out) = delta_case('[delta] computed from real before/after probe values', ['available 500000 100000 census', 'available 300000 100000 census']);
has(delta_line($out), '200000 bytes', 'the delta line reports the real before/after difference (500000 - 300000), not a guess');
is_eq('200000', T('DELTA_BYTES'), 'the grand-total delta accumulator reflects the real computed value');

($out) = delta_case('[delta] edge case 1: an action that frees nothing reports 0B explicitly', ['available 500000 424242 census', 'available 500000 424242 census']);
$dl = delta_line($out);
has($dl, '0.0B', 'an action that frees nothing reports 0B explicitly');
has($dl, '(0 bytes)', 'the zero delta is the literal computed byte count, not omitted');
hasnt($dl, '424242', 'the zero delta line never substitutes the (nonzero) reclaimable estimate');
is_eq('0', T('DELTA_BYTES'), 'the grand-total delta reflects the real zero, not the estimate');

($out) = delta_case('[delta] edge case 5: before-probe unavailable -- no delta, action skipped', ['unavailable 0 0 -']);
hasnt($out, 'observed footprint change', 'an unavailable before-probe never prints a delta line at all');
hasnt(mutate(), 'uv cache', 'an unavailable before-probe still skips the action for safety');
is_eq('0', T('DELTA_BYTES'), 'an unavailable before-probe never contributes to the grand-total delta');

($out) = delta_case('[delta] edge case 3: post-action probe failure', ['available 500000 100000 census', 'unavailable 0 0 -']);
$dl = delta_line($out);
has($dl, 'unavailable', 'a failed post-action probe reports the delta as unavailable');
has($dl, 'post-action size probe failed', 'the unavailable delta names the post-action probe as the reason');
is_eq('0', F(), 'a post-action probe failure alone does not set FAILED');
is_eq('0', T('DELTA_BYTES'), 'a runtime with an unavailable post-action probe is excluded from the grand-total delta');

(undef, undef, undef) = ();
my @r = delta_case('[delta] edge case 4: a failed action still reports the delta, labelled partial, and still fails', ['available 1000000 500000 census', 'available 700000 500000 census'], prune_rc => 1);
($out, $err, $rv) = @r;
$dl = delta_line($out);
has($dl, '300000 bytes', "a failed action's partial delta is still the real measured difference");
has($dl, 'partial result', "a failed action's delta is labelled as a partial result");
is_eq('1', F(), 'a failed verb still sets FAILED');
falsy('process_runtime still returns failure when the verb it ran failed', $rv);
is_eq('300000', T('DELTA_BYTES'), 'a partial-but-measured delta is still summed into the grand total');
has($err, 'WARNING: uv: prune failed', 'the failed verb warns');

($out) = delta_case('[delta] edge case 2: negative delta is reported signed, not clamped, not a failure', ['available 500000 100000 census', 'available 700000 100000 census']);
$dl = delta_line($out);
has($dl, '-200000 bytes', 'a negative delta is reported signed, as observed, not clamped to zero');
has($dl, 'negative', 'a negative delta carries the concurrent-write note');
is_eq('0', F(), 'a negative delta is not treated as a failure');
is_eq('-200000', T('DELTA_BYTES'), 'the grand-total delta reflects the signed negative value');

($out) = delta_case('[delta] dual-verb interactive, both confirms accepted: one delta spans both verbs', ['available 1000000 500000 census', 'available 200000 500000 census'], mode => 'interactive', purge => 1, confirm => 1);
is_eq('uv cache prune|uv cache clean|', mutate(), 'both verbs actually ran (safe then purge) ahead of the delta');
is_eq('1', scalar(() = $out =~ /observed footprint change/g), 'exactly one delta line is printed for a dual-verb run');
has(delta_line($out), '800000 bytes', 'the single delta reflects the pair spanning both verbs');
is_eq('800000', T('DELTA_BYTES'), 'the grand total reflects the one spanning delta, not two');

section('[totals] safe-tier and purge-tier reclaimable accumulate independently across a full pass');
all_present(); reset_logs(); mode('report');
{
	my %fixed = (uv => 'available 10000 1000 census', npm => 'available 20000 2000 census', pip => 'available 5000 5000 census', bun => 'available 6000 6000 census', cargo => 'available 7000 7000 census');
	my %orig = map { $_ => rt($_)->{size} } keys %fixed;
	for my $n (keys %fixed) { my $v = $fixed{$n}; rt($n)->{size} = sub { $v }; }
	proc_all();
	rt($_)->{size} = $orig{$_} for keys %orig;
}
is_eq('48000', T('TOTAL_BYTES'), "footprint total sums every runtime's total, including cargo's");
is_eq('0', T('SAFE_RECLAIMABLE_BYTES'), 'no core runtime here predicts a safe verb, so the safe tier stays 0 (docker: WP-9)');
is_eq('21000', T('PURGE_RECLAIMABLE_BYTES'), "purge-tier total sums uv+npm+pip+bun+cargo's reclaimable");

# ---- actions.sh ---------------------------------------------------------------
section('[--report] mutates nothing but does probe');
all_present(); reset_logs(); mode('report');
($out, $err) = proc_all();
is_eq('', mutate(), '--report performs no mutating calls');
has(all_log(), 'npm config get cache', 'npm cache location is resolved during report');
has(all_log(), 'pip cache dir', 'pip cache location is resolved during report');
has($out, 'total (', 'size probe runs during report and prints the total figure');
has($out, 'reclaimable via the purge verb', 'the purge-tier estimate is printed and labelled with its verb during report');
has($out, "note: uv's safe verb cannot be predicted", "uv's safe verb gets no number, only the unpredictable note");
hasnt($out, 'observed footprint change', '--report never prints a delta line');

section('[--report] mutates nothing even with --include-purge set');
all_present(); reset_logs(); mode('report', 1);
proc_all();
is_eq('', mutate(), '--report performs no mutating calls, including the purge verbs, even with --include-purge');

section('[--yes] safe prunes fire; opt-in purges do not, and are never prompted');
all_present(); reset_logs(); mode('yes');
proc_all();
has(mutate(), 'uv cache prune', 'uv is pruned under --yes');
hasnt(mutate(), 'uv cache clean', '--yes alone never purges uv');
has(mutate(), 'npm cache verify', 'npm is pruned under --yes');
hasnt(mutate(), 'npm cache clean', '--yes alone never purges npm');
hasnt(mutate(), 'pip cache purge', '--yes alone never purges pip (load-bearing)');
hasnt(mutate(), 'bun pm cache', '--yes alone never purges bun (load-bearing)');
hasnt(confirms(), 'pip', 'pip is never prompted under --yes alone');
hasnt(confirms(), 'bun', 'bun is never prompted under --yes alone');

section('[--yes --include-purge] opt-in purges fire too');
all_present(); reset_logs(); mode('yes', 1);
system('rm', '-rf', $CH); system('mkdir', '-p', "$CH/registry");
proc_all();
has(mutate(), 'pip cache purge', 'pip is purged under --yes --include-purge');
has(mutate(), 'bun pm cache', 'bun is purged under --yes --include-purge');
has(mutate(), 'uv cache clean', 'uv is purged under --yes --include-purge');
hasnt(mutate(), 'uv cache prune', "uv's purge supersedes its safe verb");
has(mutate(), 'npm cache clean', 'npm is purged under --yes --include-purge');
hasnt(mutate(), 'npm cache verify', "npm's purge supersedes its safe verb");

section('[interactive] purge prompts default to No; a declined prompt executes nothing');
all_present(); reset_logs(); mode('interactive'); $CONFIRM_RESULT = 0;
proc('pip'); proc('bun');
has(confirms(), 'pip', 'interactive mode prompts for pip');
has(confirms(), 'bun', 'interactive mode prompts for bun');
is_eq('', mutate(), 'a declined interactive purge prompt executes nothing');

section('[interactive] a declined safe-prune confirm executes nothing');
all_present(); reset_logs(); mode('interactive'); $CONFIRM_RESULT = 0;
($out) = proc('uv');
has(confirms(), 'uv', 'interactive mode prompts for uv');
is_eq('', mutate(), 'a declined interactive safe-prune executes nothing');
has($out, 'uv: skipped.', 'a runtime that did not act prints its skipped line');

section('[interactive] an accepted safe-prune confirm executes');
all_present(); reset_logs(); mode('interactive'); $CONFIRM_RESULT = 1;
proc('uv');
has(mutate(), 'uv cache prune', 'an accepted interactive confirm prunes uv');
section('[interactive] uv without --include-purge gets exactly one confirm (the safe one)');
is_eq('Prune uv cache?|', confirms(), 'exactly one confirm fires for uv, and it is the safe prune');
hasnt(confirms(), 'Purge uv cache?', 'no purge confirm is offered for uv without --include-purge');
hasnt(mutate(), 'uv cache clean', 'uv is never purged interactively without --include-purge');

section('[interactive] uv with --include-purge, both confirms accepted: both verbs run, safe first');
all_present(); reset_logs(); mode('interactive', 1); $CONFIRM_RESULT = 1;
proc('uv');
is_eq('Prune uv cache?|Purge uv cache? (opt-in, destructive)|', confirms(), 'both the safe and purge confirms are offered, safe first');
is_eq('uv cache prune|uv cache clean|', mutate(), 'both verbs run in order when both confirms are accepted');

section('[interactive] uv with --include-purge, both confirms declined: nothing runs');
all_present(); reset_logs(); mode('interactive', 1); $CONFIRM_RESULT = 0;
proc('uv');
is_eq('Prune uv cache?|Purge uv cache? (opt-in, destructive)|', confirms(), 'both confirms are still offered even though both are declined');
is_eq('', mutate(), 'declining both interactive confirms executes neither verb');

section('[interactive] a failed safe verb skips the purge election');
all_present(); reset_logs(); mode('interactive', 1); $CONFIRM_RESULT = 1; $RESULT{'uv cache prune'} = 1;
proc('uv');
is_eq('Prune uv cache?|', confirms(), 'no purge confirm follows a failed safe verb');
is_eq('uv cache prune|', mutate(), 'the purge verb never runs after a failed safe verb');

section('[interactive] pip without --include-purge is still prompted and still purges when accepted (the asymmetry)');
all_present(); reset_logs(); mode('interactive'); $CONFIRM_RESULT = 1;
proc('pip');
has(confirms(), 'Purge pip cache? (opt-in, destructive)', 'pip is prompted interactively even without --include-purge');
has(mutate(), 'pip cache purge', 'pip purges on an accepted interactive confirm even without --include-purge');

section('[bun] the purge runs from a scratch package dir, which is removed after');
all_present(); reset_logs(); mode('yes', 1);
{
	my $seen;
	my $orig = \&CachePrune::Core::cmd_run;
	local *CachePrune::Core::cmd_run = sub { my @c = @_; if (ref $c[0] eq 'HASH' && $c[1] eq 'bun') { $seen = $c[0]{dir}; } return $orig->(@_); };
	proc('bun');
	truthy('bun pm cache rm ran with a scratch working directory', defined $seen && length $seen);
	falsy('the scratch directory is removed afterwards', defined $seen && -e $seen);
}
has(mutate(), 'bun pm cache rm', 'bun pm cache rm is the purge verb');

section('[cargo] purge-only: registry/src children, filesystem-backed (sandboxed CARGO_HOME)');
sub cargo_fixture {
	system('rm', '-rf', $CH);
	system('mkdir', '-p', "$CH/registry/src/idx-1/foo-1.0/src", "$CH/registry/src/idx-1/bar-2.0", "$CH/registry/cache/idx-1", "$CH/registry/index/idx-1");
	for (["$CH/registry/src/idx-1/foo-1.0/src/lib.rs", "fn main() {}\n"], ["$CH/registry/src/idx-1/bar-2.0/lib.rs", "bar\n"], ["$CH/registry/cache/idx-1/foo-1.0.crate", 'crate'], ["$CH/registry/index/idx-1/cfg", 'idx']) {
		open(my $h, '>', $_->[0]) or die; print $h $_->[1]; close $h;
	}
}
my ($cargo_warn, $cargo_rv);
sub cargo_run { all_present(); reset_logs(); mode('yes', $_[0]); my @x = proc('cargo'); $cargo_warn = $x[1]; $cargo_rv = $x[2]; }
cargo_fixture(); cargo_run(0);
truthy('--yes alone leaves registry/src untouched', -f "$CH/registry/src/idx-1/foo-1.0/src/lib.rs");
is_eq('', mutate(), 'cargo makes no command-double mutating call');
cargo_fixture(); cargo_run(1);
is_eq('1 0', ($cargo_rv ? 1 : 0) . ' ' . F(), '--yes --include-purge purge of cargo succeeds');
opendir(my $sd, "$CH/registry/src"); my @left = grep { !/\A\.\.?\z/ } readdir $sd; closedir $sd;
is_eq('', "@left", 'purge empties registry/src children');
truthy('registry/src itself is kept', -d "$CH/registry/src");
truthy('registry/cache contents survive', -f "$CH/registry/cache/idx-1/foo-1.0.crate");
truthy('registry/index contents survive', -f "$CH/registry/index/idx-1/cfg");
truthy('lock files absent beforehand are created, never removed', -e "$CH/.package-cache" && -e "$CH/.package-cache-mutate");
for my $held ('.package-cache', '.package-cache-mutate') {
	cargo_fixture();
	sysopen(my $lh, "$CH/$held", O_RDWR | O_CREAT) or die;
	my $pid = fork;
	if ($pid == 0) { flock($lh, LOCK_EX) or exit 1; open(my $r, '>', "$SB/cargo-ready"); close $r; sleep 30; exit 0; }
	close $lh;
	for (1 .. 200) { last if -e "$SB/cargo-ready"; select(undef, undef, undef, 0.05); }
	cargo_run(1);
	kill 'TERM', $pid; waitpid($pid, 0); unlink "$SB/cargo-ready";
	truthy("held $held skips: nothing deleted", -f "$CH/registry/src/idx-1/foo-1.0/src/lib.rs");
	has($cargo_warn, "cargo: skipped $CH/registry/src (guard: a cargo package-cache lock is held)", "held $held warns");
	is_eq('1 0', ($cargo_rv ? 1 : 0) . ' ' . F(), "held $held leaves exit status and FAILED unchanged");
}
cargo_fixture();
system('rm', '-rf', "$CH/registry/src");
system('mkdir', '-p', "$SB/cargo-elsewhere/keep"); open(my $kf, '>', "$SB/cargo-elsewhere/keep/file"); print $kf 'x'; close $kf;
symlink "$SB/cargo-elsewhere", "$CH/registry/src";
cargo_run(1);
truthy('symlinked registry/src: the target contents survive', -f "$SB/cargo-elsewhere/keep/file");
has($cargo_warn, '(guard: symlinked or escapes CARGO_HOME)', 'symlinked registry/src warns');
is_eq('1 0', ($cargo_rv ? 1 : 0) . ' ' . F(), 'a symlink skip leaves exit status and FAILED unchanged');
system('rm', '-rf', "$SB/cargo-elsewhere", $CH); system('mkdir', '-p', "$CH/registry");

section('[partial failure] one failing runtime warns and is skipped; others still run; exit is nonzero');
all_present(); reset_logs(); mode('yes'); $RESULT{'uv cache prune'} = 1;
($out, $err) = proc_all();
has($err, 'uv: prune failed', 'a failing prune emits a named warning');
has(mutate(), 'npm cache verify', 'other runtimes still process after one fails');
is_eq('1', F(), 'aggregate failure flag is set');
($out) = capture(sub { CachePrune::Main::print_total() });
has($out, 'Total cache footprint seen:', 'grand total is still printed after a partial failure');

section('[tier_elected] safe / purge / interactive-only / per-item');
sub tier_matrix {
	my ($kind, $note) = @_;
	my $s = '';
	local *CachePrune::Core::confirm = sub { $s .= '?'; return 1; };
	for my $m (['report', 0], ['yes', 0], ['yes', 1], ['interactive', 0], ['interactive', 1]) {
		mode(@$m);
		my (undef, undef, $e) = capture(sub { CachePrune::Actions::tier_elected($kind, 'prompt', $note) });
		$s .= ($e ? 'E' : '-') . ' ';
	}
	return $s;
}
is_eq('- E E ?E ?E ', tier_matrix('safe'), 'safe: --yes always, interactive confirms');
is_eq('- - E - ?E ', tier_matrix('purge'), 'purge: --yes needs --include-purge, interactive confirms only with it');
is_eq('- - - ?E ?E ', tier_matrix('optin', 'interactive only'), 'interactive-only: never under --yes, interactive confirms');
is_eq('- - - - ?E ', tier_matrix('item'), 'per-item: never under --yes, interactive confirms only with --include-purge');
mode('yes', 1);
($out) = capture(sub { CachePrune::Actions::tier_elected('optin', 'p', 'skipped: only interactively') });
is_eq("skipped: only interactively\n", $out, 'the interactive-only note is printed under --yes');

section('[guarded_remove] root-contained deletion, return codes, symlinked leaf');
my ($GR, $GO) = ("$SB/guarded-root", "$SB/guarded-outside");
system('mkdir', '-p', "$GR/dir/sub", "$GO/keep"); open(my $pf, '>', "$GO/keep/payload"); print $pf 'x'; close $pf;
symlink "$GO/keep", "$GR/link";
is_eq('0', (CachePrune::Actions::guarded_remove($GR, "$GR/dir"))[0], 'guarded_remove removes a directory inside the root');
falsy('the removed directory is gone', -e "$GR/dir");
is_eq('2', (CachePrune::Actions::guarded_remove($GR, $GR))[0], 'guarded_remove refuses the root itself');
is_eq('2', (CachePrune::Actions::guarded_remove($GR, "$GO/keep"))[0], 'guarded_remove refuses a sibling outside the root');
is_eq('1', (CachePrune::Actions::guarded_remove($GR, "$GR/missing"))[0], 'guarded_remove reports a missing path as 1');
is_eq("0 $GR/link", join(' ', CachePrune::Actions::guarded_remove($GR, "$GR/link")), 'guarded_remove removes a symlinked leaf as a link and names the candidate');
truthy('the symlink target outside the root survives', -f "$GO/keep/payload");

section('[path_contained] symlinked path or mismatched realpath is refused');
symlink "$GO/keep", "$SB/contained-link";
truthy('a plain path matching its realpath is contained', CachePrune::Actions::path_contained("$GO/keep", "$GO/keep"));
falsy('a symlink is never contained', CachePrune::Actions::path_contained("$SB/contained-link", "$GO/keep"));
falsy('a missing path is never contained', CachePrune::Actions::path_contained("$SB/nope", "$SB/nope"));

section('[path_on_noatime_mount] longest-prefix mount wins; \040 in a mount path is a space');
system('mkdir', '-p', "$SB/noatime space/inner/leaf");
(my $NA = "$SB/noatime space") =~ s/ /\\040/g;
my $MF = "$SB/noatime-mounts";
open(my $mf, '>', $MF); print $mf "none / ext4 rw,noatime 0 0\nnone $NA tmpfs rw,relatime 0 0\nnone $NA/inner tmpfs rw,noatime 0 0\n"; close $mf;
truthy('the longest-prefix mount (a noatime one, escaped space path) decides', CachePrune::Actions::path_on_noatime_mount("$SB/noatime space/inner/leaf", $MF));
open($mf, '>', $MF); print $mf "none / ext4 rw,noatime 0 0\nnone $NA tmpfs rw,relatime 0 0\n"; close $mf;
falsy('a relatime mount longer than a noatime / wins', CachePrune::Actions::path_on_noatime_mount("$SB/noatime space/inner/leaf", $MF));
falsy('an unreadable mounts file reads as not noatime', CachePrune::Actions::path_on_noatime_mount("$SB/noatime space/inner/leaf", "$SB/no-such-mounts"));

section('[outermost_marker_dirs] outermost only, sibling sorting before a nested dir, validator runs before dedupe');
my $OM = "$SB/outermost";
system('mkdir', '-p', "$OM/a/sub", "$OM/a-x", "$OM/node_modules/n", "$OM/b/inner", "$OM/.git/x");
for (qw(a/m.cfg a/sub/m.cfg a-x/m.cfg node_modules/n/m.cfg b/m.cfg b/inner/m.cfg .git/x/m.cfg)) { open(my $h, '>', "$OM/$_"); close $h; }
symlink "$OM/a", "$OM/linked";
my $match = sub { $_[1] eq 'm.cfg' };
is_eq("$OM/a\n$OM/a-x\n$OM/b", join("\n", sort(CachePrune::Actions::outermost_marker_dirs($OM, undef, $match))), 'a sibling sorting between a dir and its nested dir does not hide or duplicate; node_modules/.git pruned; symlinks not followed');
is_eq("$OM/a\n$OM/a-x\n$OM/b/inner", join("\n", sort(CachePrune::Actions::outermost_marker_dirs($OM, sub { $_[0] !~ m{/b/m\.cfg\z} }, $match))), 'a rejected ancestor marker does not hide its valid nested one');

section('[path_git_tracked] a tracked path inside a work tree');
system('mkdir', '-p', "$SB/repo/t", "$SB/repo/u");
open(my $gf, '>', "$SB/repo/t/f"); close $gf;
my $git_ok = system("git -C '$SB/repo' init -q >/dev/null 2>&1 && git -C '$SB/repo' add t/f >/dev/null 2>&1") == 0;
if ($git_ok) {
	truthy('a dir holding a tracked (indexed) path is git-tracked', CachePrune::Actions::path_git_tracked("$SB/repo/t"));
	falsy('a dir with no tracked path is not', CachePrune::Actions::path_git_tracked("$SB/repo/u"));
} else { ok('path_git_tracked (skipped: git unavailable)'); }
falsy('a dir outside any work tree is not', CachePrune::Actions::path_git_tracked("$SB/census-plain"));

section('[env_days] digits or the default');
is_eq('7', CachePrune::Actions::env_days(undef, 7), 'unset reads as the default');
is_eq('7', CachePrune::Actions::env_days('', 7), 'empty reads as the default');
is_eq('7', CachePrune::Actions::env_days('x9', 7), 'non-numeric reads as the default');
is_eq('30', CachePrune::Actions::env_days('30', 7), 'all digits is taken');

# ---- cli.sh -------------------------------------------------------------------
section('[require_not_root] root refusal');
my (undef, $rerr, $rok) = capture(sub { CachePrune::Main::require_not_root(0) });
falsy('root EUID is refused', $rok);
has($rerr, 'ERROR: Refusing to run as root:', 'the refusal names the reason');
(undef, undef, $rok) = capture(sub { CachePrune::Main::require_not_root(1000) });
truthy('non-root EUID is accepted', $rok);

section('[argument parsing] unknown flags and bad --docker-until windows exit 2');
is_eq('1', (capture(sub { CachePrune::Main::main('--bogus-flag') }))[2], 'an unknown flag is a usage error: exit 1, what the bash CLI really exits (its in-function suite asserts 2)');
for my $w ('bogus', '99x', '', '168') {
	is_eq('2', (capture(sub { CachePrune::Main::main('--docker-until', $w) }))[2], "--docker-until '$w' (space form) exits 2");
	is_eq('2', (capture(sub { CachePrune::Main::main("--docker-until=$w") }))[2], "--docker-until=$w (equals form) exits 2");
}
is_eq('1', (capture(sub { CachePrune::Main::main('--docker-until') }))[2], '--docker-until without a value is a usage error (exit 1, as the bash CLI)');
$CachePrune::Core::DOCKER_UNTIL = '168h';
is_eq('0', (capture(sub { CachePrune::Main::set_docker_until('bogus') }))[2], 'set_docker_until rejects an invalid window');
is_eq('168h', $CachePrune::Core::DOCKER_UNTIL, 'a rejected window leaves DOCKER_UNTIL untouched');
is_eq('1', (capture(sub { CachePrune::Main::set_docker_until('24h') }))[2], 'set_docker_until accepts a valid window');
is_eq('24h', $CachePrune::Core::DOCKER_UNTIL, 'an accepted window is assigned');
is_eq('604800', CachePrune::Core::docker_window_seconds('168h'), '168h converts to 604800 seconds');
falsy('an unrecognised window unit is rejected', defined CachePrune::Core::docker_window_seconds('168x'));

section('[main] full run smoke: --yes and --report Total sections');
all_present(); reset_logs();
($out) = capture(sub { CachePrune::Main::main('--yes') });
has($out, 'Total cache footprint seen:', 'the --yes Total section prints the footprint total');
has($out, 'Estimated safe-tier reclaimable', 'the --yes Total section prints the safe-tier estimate, labelled');
has($out, 'Estimated purge-tier reclaimable', 'the --yes Total section prints the purge-tier estimate, labelled');
has($out, 'Observed footprint change', 'the --yes Total section prints the observed delta line, since an action ran');
all_present(); reset_logs();
($out) = capture(sub { CachePrune::Main::main('--report') });
has($out, 'Total cache footprint seen:', 'the --report Total section prints the footprint total');
has($out, 'Estimated safe-tier reclaimable', 'the --report Total section prints the safe-tier estimate, labelled');
has($out, 'Estimated purge-tier reclaimable', 'the --report Total section prints the purge-tier estimate, labelled');
hasnt($out, 'Observed footprint change', 'the --report Total section prints no delta line at all');
is_eq('', mutate(), 'a full --report run via main() still performs no mutating calls');
hasnt($out, 'Overlap:', 'no split-tier bytes: the Total block carries no overlap line');

section('[report seam] split-tier: safe_reclaimable gives a dual-verb runtime both figures; others unchanged');
my $seam = { name => 'seamfake', prune => sub { 1 }, purge => sub { 1 } };
CachePrune::Main::reset_totals();
($out) = capture(sub { CachePrune::Main::report_measurement($seam, 10240, 6144) });
is_eq("seamfake cache size: 10.0KB total (10240 bytes)\nseamfake reclaimable via the purge verb (6.0KB, 6144 bytes) -- requires --include-purge\nnote: seamfake's safe verb cannot be predicted (no dry run exists) -- it is not represented by any reclaimable figure here.\n", $out, 'a dual-verb runtime without the entry reports exactly as before');
$seam->{safe_reclaimable} = sub { 2048 };
CachePrune::Main::reset_totals();
($out) = capture(sub { CachePrune::Main::report_measurement($seam, 10240, 6144) });
has($out, 'seamfake reclaimable via the safe verb (2.0KB, 2048 bytes)', 'the safe line carries the safe-verb bytes');
has($out, 'seamfake reclaimable via the purge verb (6.0KB, 6144 bytes) -- requires --include-purge; includes the safe-verb 2.0KB above (a superset, not additive)', 'the purge line carries the superset and names the overlap');
is_eq('2048 6144 2048', join(' ', T('SAFE_RECLAIMABLE_BYTES'), T('PURGE_RECLAIMABLE_BYTES'), T('OVERLAP_RECLAIMABLE_BYTES')), 'each tier total gets its own figure; the overlap is counted for the Total block');
hasnt($out, 'cannot be predicted', 'a split-tier runtime prints no unpredicted-safe note');
($out) = capture(sub { CachePrune::Main::print_total() });
has($out, 'Overlap: 2.0KB (2048 bytes) of the safe-tier figure', 'the Total block names the overlap');
my $only = { name => 'onlyfake', purge => sub { 1 }, interactive_only => 'x' };
($out) = capture(sub { CachePrune::Main::report_measurement($only, 10, 10) });
has($out, 'onlyfake reclaimable via the purge verb (10.0B, 10 bytes) -- emptied only after an interactive confirm, never under --yes', 'an interactive-only runtime names its gate');
my $safeonly = { name => 'safefake', prune => sub { 1 }, purge => sub { 1 }, purge_unpredicted_note => 'purge note', safe_estimate_note => 'safe note' };
($out) = capture(sub { CachePrune::Main::report_measurement($safeonly, 10, 5) });
is_eq("safefake cache size: 10.0B total (10 bytes)\nsafefake reclaimable via the safe verb (5.0B, 5 bytes)\nsafe note\npurge note\n", $out, 'a safe-predicting dual-verb runtime prints the safe line, its estimate note and the purge-scope note');

section('[residue / detail / interactive_only] lifecycle seams a fake runtime exercises');
my @trace;
CachePrune::Runtime::register_runtime({
	name => 'seamrt', detect => sub { 1 }, size => sub { 'available 10 10 census' },
	purge => sub { push @trace, 'purge'; 1 }, detail => sub { print "seamrt detail\n" },
	residue => sub { push @trace, 'residue'; 1 }, interactive_only => 'skipped: seamrt needs an interactive confirm',
	purge_prompt => sub { 'Custom seamrt prompt?' },
});
reset_logs(); mode('yes', 1); @trace = ();
($out) = proc('seamrt');
has($out, "seamrt detail\n", 'the detail hook prints right after the size lines');
has($out, 'skipped: seamrt needs an interactive confirm', 'interactive_only prints its note under --yes --include-purge');
is_eq('residue', "@trace", 'interactive_only never runs the purge under --yes; the residue step still runs');
hasnt($out, 'seamrt: skipped.', 'a residue step that removed something counts as acted');
reset_logs(); mode('interactive'); $CONFIRM_RESULT = 1; @trace = ();
proc('seamrt');
is_eq('Custom seamrt prompt?|', confirms(), 'purge_prompt replaces the generic interactive purge prompt');
is_eq('purge residue', "@trace", 'an accepted interactive confirm runs the purge, then the residue step');
reset_logs(); mode('report'); @trace = ();
proc('seamrt');
is_eq('', "@trace", '--report runs neither verbs nor the residue step');
@CachePrune::Runtime::ORDER = grep { $_->{name} ne 'seamrt' } @CachePrune::Runtime::ORDER;
delete $CachePrune::Runtime::BY_NAME{seamrt};

section('[registry] register_runtime validates its spec');
for my $bad (['no name', {}], ['no detect', { name => 'x1', size => sub { 1 } }], ['no size', { name => 'x2', detect => sub { 1 } }],
	['unknown key', { name => 'x3', detect => sub { 1 }, size => sub { 1 }, bogus => 1 }],
	['hook not code', { name => 'x4', detect => sub { 1 }, size => sub { 1 }, purge => 'str' }],
	['duplicate', { name => 'uv', detect => sub { 1 }, size => sub { 1 } }],
	['bad help slot', { name => 'x5', detect => sub { 1 }, size => sub { 1 }, help => { nope => 'x' } }]) {
	falsy("register_runtime dies on $bad->[0]", eval { CachePrune::Runtime::register_runtime($bad->[1]); 1 });
}
is_eq('uv npm pip bun cargo', join(' ', map { $_->{name} } @CachePrune::Runtime::ORDER), 'a rejected spec registers nothing');

# ---- missing-tool.sh ----------------------------------------------------------
section('[missing tool] a runtime whose CLI is absent says no <tool> on host and does not fail');
for my $t (qw(uv npm pip bun cargo)) {
	all_present(); delete $PRESENT{$t}; reset_logs(); mode('report');
	my ($o2, $e2, $r2) = proc($t);
	has($o2, "skip: $t: no $t on host", "$t: a missing executable is named");
	is_eq('1 0', ($r2 ? 1 : 0) . ' ' . F(), "$t: a missing executable never changes the exit status");
}
CachePrune::Runtime::register_runtime({ name => 'noreason', detect => sub { 0 }, size => sub { '' } });
($out) = proc('noreason');
has($out, 'skip: noreason: not detected', 'a runtime without an absent hook reads not detected');
@CachePrune::Runtime::ORDER = grep { $_->{name} ne 'noreason' } @CachePrune::Runtime::ORDER;

printf "\nUNIT %d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
