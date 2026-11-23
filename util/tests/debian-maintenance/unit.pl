#!/usr/bin/perl
# CC0: This work has been marked as dedicated to the public domain.
# Unit cases for util/debian-maintenance/debian-maintenance.pl, run by ../debian-maintenance.sh.
# The program is loaded with `require` (defines subs, does not run main); the command seam
# (cmd_capture/cmd_run/have_cmd) and confirm are replaced with in-process fakes, so nothing real
# is executed except `dpkg --compare-versions` for the version sort.
use strict;
use warnings;
no warnings qw(redefine once);

my $prog = $ARGV[0] or die "usage: unit.pl <debian-maintenance.pl>\n";
$prog = "./$prog" unless $prog =~ m{\A/}; require $prog;

my ($pass, $fail) = (0, 0);
sub ok { $pass++; print "  ok   - $_[0]\n"; }
sub bad { $fail++; print "  FAIL - $_[0]\n"; }
sub is_eq { my ($exp, $got, $label) = @_; $got = '<undef>' unless defined $got; $exp eq $got ? ok($label) : bad("$label (expected <$exp>, got <$got>)"); }
sub truthy { my ($label, $v) = @_; $v ? ok($label) : bad($label); }
sub like_is { my ($v, $re, $label) = @_; $v =~ $re ? ok($label) : bad("$label (got <$v>)"); }
sub falsy { my ($label, $v) = @_; $v ? bad($label) : ok($label); }
sub contains { my ($needle, @list) = @_; return scalar grep { $_ eq $needle } @list; }

# ---- fakes ------------------------------------------------------------------
our %CAPTURE;     # command name -> sub(@args) returning (out, rc)
our @RUN_LOG;     # "name args" for every non-compare cmd_run
our @CONFIRMS;    # queue of 1/0 answers; empty queue answers no
our %HAVE = (journalctl => 1);
my $real_run = \&main::cmd_run;
*main::cmd_capture = sub {
	my ($stderr, $name, @args) = @_;
	return $CAPTURE{$name} ? $CAPTURE{$name}->(@args) : ('', 127);
};
*main::cmd_run = sub {
	my ($name, @args) = @_;
	return $real_run->($name, @args) if $name eq 'dpkg' && @args && $args[0] eq '--compare-versions';
	push @RUN_LOG, "$name @args";
	return 0;
};
*main::have_cmd = sub { return $HAVE{$_[0]}; };
*main::confirm = sub { return @CONFIRMS ? shift @CONFIRMS : 0; };
sub quiet { my ($code) = @_; open(my $o, '>&', \*STDOUT); open(my $e, '>&', \*STDERR); open(STDOUT, '>', '/dev/null'); open(STDERR, '>', '/dev/null'); my @r = $code->(); open(STDOUT, '>&', $o); open(STDERR, '>&', $e); return @r; }
sub run_log { return join '', map { "$_|" } @RUN_LOG; }

# ---- inventory ---------------------------------------------------------------
print "[inventory] installed-status filtering\n";
$CAPTURE{'dpkg-query'} = sub { return (join("\n", "linux-image-6.1.0-1-amd64\t6.1.1\tii ", "linux-image-6.1.0-2-amd64\t6.1.2\trc ", "linux-image-unsigned-6.1.0-3-amd64\t6.1.3\thi ", "linux-image-amd64\t6.1.3\tii "), 0); };
is_eq("linux-image-6.1.0-1-amd64\t6.1.1\nlinux-image-unsigned-6.1.0-3-amd64\t6.1.3",
	join("\n", map { "$_->[0]\t$_->[1]" } main::query_installed_kernel_records()),
	'only fully installed concrete signed/unsigned images survive');

# ---- retention -----------------------------------------------------------------
print "[retention] newest two plus running\n";
$CAPTURE{'dpkg-query'} = sub { return (join("\n", "linux-image-6.1.0-1-amd64\t6.1.1\tii ", "linux-image-6.1.0-2-amd64\t6.1.2\tii ", "linux-image-6.1.0-3-amd64\t6.1.3\tii "), 0); };
*main::boot_artifact_exists = sub { return $_[0] ne 'missing'; };
my @k = main::load_installed_kernels();
my ($prot, $rem) = quiet(sub { main::select_protected_kernels('6.1.0-3-amd64', @k) });
truthy('newest running kernel is recognized', $prot);
is_eq(2, scalar @{$prot || []}, 'exactly two kernels protected when newest is running');
is_eq('linux-image-6.1.0-1-amd64', join(' ', @{$rem || []}), 'oldest kernel is the only removal candidate');
($prot, $rem) = quiet(sub { main::select_protected_kernels('6.1.0-1-amd64', @k) });
truthy('older running kernel is recognized', $prot);
is_eq(3, scalar @{$prot || []}, 'running kernel is retained in addition to newest two');
is_eq(0, scalar @{$rem || []}, 'no kernel is removable when all three are protected');
($prot) = quiet(sub { main::select_protected_kernels('6.1.0-99-amd64', @k) });
falsy('missing running package blocks cleanup', $prot);
*main::boot_artifact_exists = sub { return $_[0] ne '6.1.0-2-amd64'; };
($prot) = quiet(sub { main::select_protected_kernels('6.1.0-3-amd64', @k) });
falsy('missing protected boot artifact blocks cleanup', $prot);
is_eq('linux-image-6.1.0-1-amd64 linux-image-6.1.0-2-amd64 linux-image-6.1.0-3-amd64', join(' ', map { $_->{package} } @k), 'kernels sort oldest to newest by dpkg version');

# ---- purge list ------------------------------------------------------------------
print "[purge list] exact release companions\n";
*main::boot_artifact_exists = sub { 1 };
($prot, $rem) = main::select_protected_kernels('6.1.0-3-amd64', @k);
my %installed = map { $_ => 1 } qw(linux-image-6.1.0-1-amd64 linux-headers-6.1.0-1-amd64 linux-modules-6.1.0-1-amd64);
*main::package_is_installed = sub { return $installed{$_[0]}; };
my @purge = main::build_kernel_purge_list(@$rem);
truthy('old image included', contains('linux-image-6.1.0-1-amd64', @purge));
truthy('old modules included', contains('linux-modules-6.1.0-1-amd64', @purge));
falsy('protected image excluded', contains('linux-image-6.1.0-3-amd64', @purge));
falsy('shared ABI header is not guessed', contains('linux-headers-6.1.0-1', @purge));

# ---- transaction policy ----------------------------------------------------------
print "[transaction policy] boot-critical removals\n";
truthy('kernel image is boot critical', main::is_boot_critical_package('linux-image-6.1.0-1-amd64'));
truthy('kernel modules are boot critical', main::is_boot_critical_package('linux-modules-6.1.0-1-amd64'));
truthy('GRUB is boot critical', main::is_boot_critical_package('grub-efi-amd64'));
truthy('initramfs tools are boot critical', main::is_boot_critical_package('initramfs-tools-core'));
falsy('ordinary orphan is not boot critical', main::is_boot_critical_package('orphaned-library'));

our $SIM = '';
$CAPTURE{'apt-get'} = sub { return ($SIM, 0); };
sub stage { my ($sub, $sim, @answers) = @_; $SIM = $sim; @RUN_LOG = (); @CONFIRMS = @answers; quiet($sub); return run_log(); }
is_eq('', stage(\&main::run_full_upgrade, "Inst package-a\nRemv linux-image-6.1.0-1-amd64", 1), 'full-upgrade is blocked for kernel removal');
is_eq('apt-get -y full-upgrade|', stage(\&main::run_full_upgrade, "Inst package-a\nRemv obsolete-library", 1), 'approved benign full-upgrade runs once');
is_eq('', stage(\&main::run_full_upgrade, "Inst package-a\nRemv obsolete-library", 0), 'declined full-upgrade does not execute');
is_eq('', stage(\&main::run_autoremove, 'Remv linux-modules-6.1.0-1-amd64', 1), 'autoremove is blocked for kernel modules');
is_eq('apt-get -y autoremove --purge|', stage(\&main::run_autoremove, 'Remv orphaned-library', 1), 'approved benign autoremove runs once');
is_eq('apt-get -y upgrade --with-new-pkgs|', stage(\&main::run_upgrade, 'Inst package-a', 1), 'approved upgrade runs once');
is_eq('', stage(\&main::run_upgrade, 'Inst package-a', 0), 'declined upgrade does not execute');


# ---- build companions --------------------------------------------------------------
print "[build companions] Depends-derived -common/kbuild, post-reboot fallback strip\n";
is_eq('linux-base linux-headers-6.12.116+deb13-common linux-image-6.12.116+deb13-amd64 linux-image-6.12.116+deb13-amd64-unsigned linux-kbuild-6.12.116+deb13 gcc-14',
	join(' ', main::depends_names('linux-base (>= 4.12~), linux-headers-6.12.116+deb13-common (= 6.12.116-1), linux-image-6.12.116+deb13-amd64 (= 6.12.116-1) | linux-image-6.12.116+deb13-amd64-unsigned (= 6.12.116-1), linux-kbuild-6.12.116+deb13, gcc-14')),
	'Depends parsing strips version constraints and splits alternatives');
sub trixie_dep { my ($v) = @_; return "linux-base (>= 4.12~), linux-headers-6.12.$v+deb13-common (= 6.12.$v-1), linux-image-6.12.$v+deb13-amd64 (= 6.12.$v-1) | linux-image-6.12.$v+deb13-amd64-unsigned (= 6.12.$v-1), linux-kbuild-6.12.$v+deb13, gcc-14"; }
our %DEPENDS;
our $KREC = '';
$CAPTURE{'dpkg-query'} = sub {
	my @a = @_;
	return ($DEPENDS{$a[2]}, defined $DEPENDS{$a[2]} ? 0 : 1) if $a[1] eq '-f=${Depends}';
	return ($KREC, 0);
};
sub kset { return map { { package => "linux-image-6.12.$_+deb13-amd64", version => "6.12.$_-1", release => "6.12.$_+deb13-amd64" } } @_; }
sub tri_installed { my %i; for my $v (@_) { $i{$_} = 1 for ("linux-image-6.12.$v+deb13-amd64", "linux-headers-6.12.$v+deb13-amd64", "linux-headers-6.12.$v+deb13-common", "linux-kbuild-6.12.$v+deb13", "linux-modules-6.12.$v+deb13-amd64"); } $i{'linux-base'} = 1; return %i; }
%DEPENDS = map { ("linux-headers-6.12.$_+deb13-amd64" => trixie_dep($_)) } 115, 116, 117;
%installed = tri_installed(116, 117);
my @tk = kset(116, 117);
my $plan = main::derive_kernel_purge_plan('6.12.117+deb13-amd64', \@tk, [map { $_->{package} } @tk], []);
is_eq('', join(' ', @{$plan->{images}}), 'post-reboot: no image is removable');
is_eq('linux-headers-6.12.116+deb13-amd64 linux-headers-6.12.116+deb13-common linux-kbuild-6.12.116+deb13', join(' ', @{$plan->{stripped}}), 'post-reboot: fallback headers, -common and kbuild are stripped');
falsy('post-reboot: fallback image kept', grep { /\Alinux-(?:image|modules)-/ } @{$plan->{stripped}});
falsy('post-reboot: running kernel build packages kept', grep { /117/ } @{$plan->{stripped}});
$plan = main::derive_kernel_purge_plan('6.12.116+deb13-amd64', \@tk, [map { $_->{package} } @tk], []);
is_eq('', join(' ', @{$plan->{images}}, @{$plan->{stripped}}), 'pre-reboot (running is not newest): nothing is stripped');
%installed = tri_installed(115, 116, 117);
@tk = kset(115, 116, 117);
$plan = main::derive_kernel_purge_plan('6.12.116+deb13-amd64', \@tk, [map { $_->{package} } @tk[1, 2]], [$tk[0]{package}]);
is_eq('linux-image-6.12.115+deb13-amd64 linux-headers-6.12.115+deb13-amd64 linux-modules-6.12.115+deb13-amd64', join(' ', @{$plan->{images}}), 'pre-reboot: removable kernel exact companions');
is_eq('linux-headers-6.12.115+deb13-common linux-kbuild-6.12.115+deb13', join(' ', @{$plan->{stripped}}), 'pre-reboot: removable kernel derived -common/kbuild companions');
# bookworm-style shared kbuild: linux-kbuild-6.1 is depended on by every 6.1 headers package.
%installed = map { $_ => 1 } qw(linux-image-6.1.0-1-amd64 linux-headers-6.1.0-1-amd64 linux-headers-6.1.0-1-common linux-image-6.1.0-2-amd64 linux-headers-6.1.0-2-amd64 linux-headers-6.1.0-2-common linux-image-6.1.0-3-amd64 linux-headers-6.1.0-3-amd64 linux-headers-6.1.0-3-common linux-kbuild-6.1);
%DEPENDS = map { ("linux-headers-6.1.0-$_-amd64" => "linux-headers-6.1.0-$_-common (= 6.1.$_-1), linux-kbuild-6.1 (>= 6.1.$_-1)") } 1, 2, 3;
$plan = main::derive_kernel_purge_plan('6.1.0-3-amd64', \@k, [map { $_->{package} } @k[1, 2]], [$k[0]{package}]);
is_eq('linux-headers-6.1.0-2-amd64 linux-headers-6.1.0-1-common linux-headers-6.1.0-2-common', join(' ', @{$plan->{stripped}}), 'companion shared with the retained running kernel (linux-kbuild-6.1) is excluded');
falsy('shared kbuild never purged', contains('linux-kbuild-6.1', @{$plan->{stripped}}));

print "[build companions] run_kernel_cleanup transaction check\n";
%installed = tri_installed(116, 117);
%DEPENDS = map { ("linux-headers-6.12.$_+deb13-amd64" => trixie_dep($_)) } 116, 117;
$KREC = join("\n", "linux-image-6.12.116+deb13-amd64\t6.12.116-1\tii ", "linux-image-6.12.117+deb13-amd64\t6.12.117-1\tii ");
$CAPTURE{uname} = sub { return ('6.12.117+deb13-amd64', 0); };
my $exact = "Purg linux-headers-6.12.116+deb13-amd64 [6.12.116-1]\nPurg linux-headers-6.12.116+deb13-common [6.12.116-1]\nPurg linux-kbuild-6.12.116+deb13 [6.12.116-1]";
is_eq('apt-get -y purge linux-headers-6.12.116+deb13-amd64 linux-headers-6.12.116+deb13-common linux-kbuild-6.12.116+deb13|',
	stage(\&main::run_kernel_cleanup, $exact, 1), 'confirmed post-reboot strip runs one purge of the build companions');
is_eq('', stage(\&main::run_kernel_cleanup, $exact, 0), 'declined kernel purge executes nothing');
is_eq('', stage(\&main::run_kernel_cleanup, "$exact\nPurg some-dkms-module [1.0]", 1), 'an unlisted Purg in the simulated purge refuses the kernel purge');
is_eq('', stage(\&main::run_kernel_cleanup, "$exact\nRemv some-dkms-module [1.0]", 1), 'an unlisted Remv in the simulated purge refuses the kernel purge');

# ---- rc kernels --------------------------------------------------------------------
print "[rc kernels] removed-but-not-purged sweep\n";
our $RC = join("\n", "linux-image-6.1.0-1-amd64\trc ", "linux-image-6.1.0-3-amd64\tii ", "linux-modules-6.1.0-1-amd64\trc ", "linux-modules-extra-6.1.0-0-amd64\trc ", "linux-image-unsigned-6.1.0-9-amd64:amd64\trc ", "linux-image-6.1.0-4-amd64\tiU ", "linux-image-6.1.0-5-amd64\trc ", "linux-image-amd64\tii ");
$CAPTURE{'dpkg-query'} = sub { return ($RC, 0); };
is_eq("linux-image-6.1.0-1-amd64\nlinux-modules-6.1.0-1-amd64\nlinux-modules-extra-6.1.0-0-amd64\nlinux-image-unsigned-6.1.0-9-amd64\nlinux-image-6.1.0-5-amd64",
	join("\n", main::query_rc_kernel_packages()), 'only exact rc-state image/modules packages are listed, arch suffix stripped');
is_eq('6.1.0-0-amd64', main::rc_kernel_release_for_package('linux-modules-extra-6.1.0-0-amd64'), 'modules-extra release is parsed');
is_eq('6.1.0-9-amd64', main::rc_kernel_release_for_package('linux-image-unsigned-6.1.0-9-amd64'), 'unsigned image release is parsed');
my @rc = main::load_rc_kernel_packages('6.1.0-5-amd64');
falsy('an rc package named for the running kernel is never listed', contains('linux-image-6.1.0-5-amd64', @rc));
is_eq(4, scalar @rc, 'the other rc packages are listed');
$CAPTURE{uname} = sub { return ('6.1.0-3-amd64', 0); };
is_eq('dpkg --purge linux-image-6.1.0-1-amd64 linux-modules-6.1.0-1-amd64 linux-modules-extra-6.1.0-0-amd64 linux-image-unsigned-6.1.0-9-amd64 linux-image-6.1.0-5-amd64|',
	stage(\&main::run_rc_kernel_cleanup, '', 1), 'confirmed rc sweep purges every rc kernel package once, not blocked as boot-critical');
is_eq('', stage(\&main::run_rc_kernel_cleanup, '', 0), 'declined rc sweep executes nothing');
$RC = "linux-image-6.1.0-3-amd64\tii ";
is_eq('', stage(\&main::run_rc_kernel_cleanup, '', 1), 'no rc packages: nothing executes even when confirm would accept');

# ---- archive cleanup -----------------------------------------------------------------
print "[archive cleanup] Del-format parser (the autoclean trap)\n";
truthy('Del-format preview is recognised as archive work', main::archive_transaction_has_changes('Del chatgpt 26.818.61809 [389 MB]'));
falsy('Inst/Remv-only preview is not treated as archive work', main::archive_transaction_has_changes("Inst package-a\nRemv obsolete-library"));
print "[archive cleanup] run_apt_cache_cleanup stages\n";
$CAPTURE{du} = sub { return ("1.0K\t$_[1]", 0); };
my $DEL = 'Del chatgpt 26.818.61809 [389 MB]';
is_eq('', stage(\&main::run_apt_cache_cleanup, '', 0), 'empty/no-op preview plus declined clean: nothing executes');
is_eq('apt-get -y autoclean|', stage(\&main::run_apt_cache_cleanup, $DEL, 1, 0), 'confirmed autoclean runs apt-get -y autoclean exactly once');
is_eq('', stage(\&main::run_apt_cache_cleanup, $DEL, 0, 0), 'declined autoclean executes nothing');
my $log = stage(\&main::run_apt_cache_cleanup, $DEL, 1, 0);
($log eq 'apt-get -y autoclean|') ? ok('clean runs only after its own separate confirm') : bad("clean must not run before its own separate confirm (log: $log)");
is_eq('apt-get -y autoclean|apt-get -y clean|', stage(\&main::run_apt_cache_cleanup, $DEL, 1, 1), 'confirming both runs autoclean then clean, in that order');
$CAPTURE{du} = sub { return ('du: cannot access', 1); };
is_eq('', stage(\&main::run_apt_cache_cleanup, $DEL, 1, 1), 'unreadable archive footprint skips the stage even when confirm would accept');

# ---- journal cleanup -----------------------------------------------------------------
print "[journal cleanup] run_journal_cleanup\n";
our $JRC = 0;
$CAPTURE{journalctl} = sub { return ('Archived and active journals take up 633.4M in the file system.', $JRC); };
is_eq('', stage(\&main::run_journal_cleanup, '', 0), 'declined journal vacuum executes nothing');
is_eq('journalctl --vacuum-size=200M|', stage(\&main::run_journal_cleanup, '', 1), 'confirmed journal vacuum runs --vacuum-size at the cap exactly once');
$JRC = 1;
is_eq('', stage(\&main::run_journal_cleanup, '', 1), 'unreadable journal usage skips the vacuum even when confirm would accept');
$JRC = 0;
%HAVE = ();
{
	open(my $o, '>&', \*STDOUT); close(STDOUT); my $buf = '';
	open(STDOUT, '>', \$buf); @RUN_LOG = (); @CONFIRMS = (1);
	main::run_journal_cleanup(); close(STDOUT); open(STDOUT, '>&', $o);
	($buf =~ /journalctl not found/ && run_log() eq '') ? ok('missing journalctl skips the stage') : bad("missing journalctl should skip (got: $buf)");
}

# ---- next steps ------------------------------------------------------------------------
print "[next steps] closing print-only block\n";
$ENV{TMPDIR} //= '/tmp';
my $ntmp = "$ENV{TMPDIR}/dm-next-$$";
mkdir $ntmp or die "mkdir $ntmp: $!";
$main::REBOOT_REQUIRED_FILE = "$ntmp/reboot-required";
$main::REBOOT_REQUIRED_PKGS_FILE = "$ntmp/reboot-required.pkgs";
sub touch { open(my $f, '>', $_[0]) or die; print $f $_[1] // ''; close($f); }
sub next_steps { my $buf = ''; open(my $o, '>&', \*STDOUT); close(STDOUT); open(STDOUT, '>', \$buf); @RUN_LOG = (); main::run_next_steps(); close(STDOUT); open(STDOUT, '>&', $o); return $buf; }
$ENV{DEBIAN_MAINTENANCE_SHIM} = '/opt/x/debian-maintenance.sh';
*main::boot_artifact_exists = sub { 1 };
%installed = map { $_ => 1 } qw(linux-image-6.1.0-1-amd64 linux-image-6.1.0-2-amd64 linux-image-6.1.0-3-amd64);
$CAPTURE{'dpkg-query'} = sub { return (join("\n", "linux-image-6.1.0-1-amd64\t6.1.1\tii ", "linux-image-6.1.0-2-amd64\t6.1.2\tii ", "linux-image-6.1.0-3-amd64\t6.1.3\tii "), 0); };
$CAPTURE{uname} = sub { return ('6.1.0-2-amd64', 0); };
@CONFIRMS = (1);
my $out = next_steps();
is_eq("\n==== NEXT STEPS ====\nOPEN: reboot required — running 6.1.0-2-amd64, newest installed 6.1.0-3-amd64\nOPEN: after the reboot, re-run: sudo /opt/x/debian-maintenance.sh — kernel purge candidates (simulated and confirmed by that run): linux-image-6.1.0-1-amd64\n", $out, 'running older than newest: both OPEN lines with the purge candidates');
is_eq('', run_log(), 'next steps runs nothing');
is_eq('1', join(',', @CONFIRMS), 'next steps consumes no confirm answer');
touch($main::REBOOT_REQUIRED_FILE); touch($main::REBOOT_REQUIRED_PKGS_FILE, "libc6\nlinux-image-6.1.0-3-amd64\nlibc6\n");
$CAPTURE{uname} = sub { return ('6.1.0-3-amd64', 0); };
my $dq = $CAPTURE{'dpkg-query'}; $CAPTURE{'dpkg-query'} = sub { return (join("\n", "linux-image-6.1.0-2-amd64\t6.1.2\tii ", "linux-image-6.1.0-3-amd64\t6.1.3\tii "), 0); };
$out = next_steps();
like_is($out, qr/OPEN: reboot required — packages: libc6 linux-image-6\.1\.0-3-amd64\n/, 'marker with pkgs file: deduped package names, no kernel reason');
like_is($out, qr/ — no kernel purge predicted\n\z/, 'marker, newest running: no kernel purge predicted');
$CAPTURE{'dpkg-query'} = $dq;
unlink $main::REBOOT_REQUIRED_PKGS_FILE;
like_is(next_steps(), qr/OPEN: reboot required — reboot-required marker present\n/, 'marker without pkgs file or kernel reason: generic reason');
*main::boot_artifact_exists = sub { 0 };
$CAPTURE{uname} = sub { return ('6.1.0-2-amd64', 0); };
$out = next_steps();
like_is($out, qr/ — purge prediction unavailable\n\z/, 'selector refusal: purge prediction unavailable');
*main::boot_artifact_exists = sub { 1 };
unlink $main::REBOOT_REQUIRED_FILE;
$CAPTURE{uname} = sub { return ('6.1.0-3-amd64', 0); };
is_eq("\n==== NEXT STEPS ====\nNEXT STEPS: none — no reboot pending.\n", next_steps(), 'nothing pending: none line');
$CAPTURE{uname} = sub { return ('', 127); };
like_is(next_steps(), qr/NEXT STEPS: none/, 'uname failure alone is not pending');
is_eq('', run_log(), 'no stage pushed to the run log');
is_eq('1', join(',', @CONFIRMS), 'sentinel confirm answer is still queued');
@CONFIRMS = ();
delete $ENV{DEBIAN_MAINTENANCE_SHIM};
rmdir $ntmp;

printf "UNIT %d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
