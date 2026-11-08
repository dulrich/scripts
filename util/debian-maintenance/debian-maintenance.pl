#!/usr/bin/perl
# CC0: This work has been marked as dedicated to the public domain.
#
# debian-maintenance.pl: conservative, interactive APT maintenance for Debian-based systems,
# perl port of the former bash util/debian-maintenance.sh. Not a router subcommand (mode 644):
# the dash shim util/debian-maintenance.sh owns --help/--build/--version and execs this file.
#
# Invocation:
#   util/debian-maintenance.sh [--report]        (shim; sets DEBIAN_MAINTENANCE_SHIM to its own resolved path)
#   perl - --report < debian-maintenance.pl      (pipe; the fleet host scanner runs it this way on remote nodes)
# --report needs nothing beside this source: no $0, no sibling files, no root, no TTY.
#
# Self-elevation: a non-root interactive run re-execs `sudo -- $DEBIAN_MAINTENANCE_SHIM` (the shim's
# absolute path, so `util debian-maintenance` works unprefixed); without the env var it re-execs
# `sudo -- perl <abs $0>`; without sudo on PATH it fails with "Run as root, e.g.: sudo ...".
#
# Kernel and bootloader package hooks own initramfs/GRUB regeneration; this program deliberately
# does not retry or repair those hooks. Every destructive step requires its own explicit confirm.
#
# Structure: stage subs run_upgrade, run_full_upgrade, run_kernel_cleanup, run_autoremove,
# run_rc_kernel_cleanup, run_apt_cache_cleanup, run_journal_cleanup; run_report for --report.
# All external commands go through cmd_capture/cmd_run, the seam the unit tests replace.
# Loaded with `require` (tests) it defines subs only; main() runs when it is the program.
#
# perl-base + JSON::PP only.
use strict;
use warnings;
use JSON::PP ();

our $KEEP_NEWEST_KERNELS = 2;
our $JOURNAL_VACUUM_SIZE = '200M';
our $APT_LISTS_DIR = '/var/lib/apt/lists';
our $ARCHIVE_DIR = '/var/cache/apt/archives';
our $REBOOT_REQUIRED_FILE = '/var/run/reboot-required';

# ---- command seam -----------------------------------------------------------

# cmd_capture($stderr, @cmd): run @cmd, return (stdout with trailing newlines stripped, exit status).
# $stderr: 'keep' (inherit), 'null' (discard) or 'merge' (into the captured output). A command
# that cannot be executed returns status 127.
sub cmd_capture {
	my ($stderr, @cmd) = @_;
	my $pid = open(my $fh, '-|');
	return ('', 127) unless defined $pid;
	if ($pid == 0) {
		if ($stderr eq 'null') {
			open(STDERR, '>', '/dev/null');
		} elsif ($stderr eq 'merge') {
			open(STDERR, '>&', \*STDOUT);
		}
		{ no warnings 'exec'; exec { $cmd[0] } @cmd; }
		exit 127;
	}
	local $/;
	my $out = <$fh>;
	$out = '' unless defined $out;
	close($fh);
	my $rc = $? == -1 ? 127 : ($? & 127 ? 128 + ($? & 127) : $? >> 8);
	$out =~ s/\n+\z//;
	return ($out, $rc);
}

# cmd_run(@cmd): run @cmd with inherited stdio, return its exit status.
sub cmd_run {
	my @cmd = @_;
	my $rc;
	{ no warnings 'exec'; $rc = system { $cmd[0] } @cmd; }
	return 127 if $rc == -1;
	return $? & 127 ? 128 + ($? & 127) : $? >> 8;
}

sub have_cmd {
	my ($name) = @_;
	for my $dir (split /:/, (defined $ENV{PATH} ? $ENV{PATH} : '')) {
		next if $dir eq '';
		return "$dir/$name" if -f "$dir/$name" && -x _;
	}
	return undef;
}

# A failed mandatory step aborts the run, as `set -e` did.
sub must_run {
	my @cmd = @_;
	my $rc = cmd_run(@cmd);
	die_exit($rc, "command failed (exit $rc): @cmd") if $rc != 0;
	return 1;
}

sub must_capture {
	my @cmd = @_;
	my ($out, $rc) = cmd_capture('keep', @cmd);
	die_exit($rc, "command failed (exit $rc): @cmd") if $rc != 0;
	return $out;
}

# ---- output helpers ---------------------------------------------------------

sub section { printf "\n==== %s ====\n", $_[0]; }

sub err { printf STDERR "ERROR: %s\n", $_[0]; return 0; }

sub die_exit {
	my ($rc, $msg) = @_;
	err($msg);
	exit($rc || 1);
}

sub confirm {
	my $prompt = defined $_[0] ? $_[0] : 'Continue?';
	print STDERR "$prompt [y/N] ";
	my $reply = <STDIN>;
	return 0 unless defined $reply;
	chomp $reply;
	return $reply =~ /\A(?:y|Y|yes|YES)\z/ ? 1 : 0;
}

sub lines_of { my ($text) = @_; return grep { $_ ne '' } split /\n/, (defined $text ? $text : ''); }

sub program_name { return defined $ENV{DEBIAN_MAINTENANCE_SHIM} ? $ENV{DEBIAN_MAINTENANCE_SHIM} : $0; }

# ---- privilege / terminal ---------------------------------------------------

sub require_root {
	my @args = @_;
	return 1 if $> == 0;
	# The `util` router is a shell alias, which `sudo` alone cannot see (and secure_path drops the
	# user PATH), so re-exec the shim by absolute path under sudo.
	if (have_cmd('sudo')) {
		my $shim = $ENV{DEBIAN_MAINTENANCE_SHIM};
		if (defined $shim && $shim ne '') {
			exec { 'sudo' } 'sudo', '--', $shim, @args;
		} elsif ($0 ne '-' && $0 ne '-e' && -r $0) {
			my ($abs) = cmd_capture('null', 'realpath', '--', $0);
			exec { 'sudo' } 'sudo', '--', 'perl', ($abs ne '' ? $abs : $0), @args;
		}
	}
	die_exit(1, 'Run as root, e.g.: sudo ' . program_name());
}

sub require_tty {
	die_exit(1, 'An interactive terminal is required.') unless -t STDIN && -t STDOUT;
	return 1;
}

# ---- transaction parsing / policy ------------------------------------------

sub transaction_has_changes { return scalar grep { /^(?:Inst|Remv) / } split /\n/, $_[0]; }

sub extract_removals { return map { /^Remv (\S+)/ ? $1 : () } split /\n/, $_[0]; }

sub is_boot_critical_package {
	my ($p) = @_;
	return 1 if $p eq 'linux-base' || $p eq 'linux-firmware' || $p eq 'shim';
	return 1 if $p =~ /\A(?:linux-image-|linux-modules-|grub-|grub2-|shim-|initramfs-tools)/;
	return 0;
}

sub validate_no_boot_removals {
	my $blocked = 0;
	for my $p (@_) {
		if (is_boot_critical_package($p)) {
			print STDERR "  BLOCKED boot-critical removal: $p\n";
			$blocked = 1;
		}
	}
	return !$blocked;
}

# apt-get -s autoclean emits `Del ` lines, not the `Inst`/`Remv` lines transaction_has_changes
# matches; deliberately a separate helper, which would otherwise silently see "no changes" forever.
sub archive_transaction_has_changes { return scalar grep { /^Del / } split /\n/, $_[0]; }

# ---- stages ----------------------------------------------------------------

sub run_upgrade {
	section('Upgradeable packages (new dependencies allowed)');
	my $sim = must_capture('apt-get', '-s', 'upgrade', '--with-new-pkgs');
	print "$sim\n";
	if (!transaction_has_changes($sim)) {
		print "No upgradeable packages.\n";
		return 1;
	}
	if (confirm('Apply package upgrades?')) {
		must_run('apt-get', '-y', 'upgrade', '--with-new-pkgs');
	} else {
		print "Skipping package upgrades.\n";
	}
	return 1;
}

sub run_full_upgrade {
	section('Full-upgrade review');
	my $sim = must_capture('apt-get', '-s', 'full-upgrade');
	print "$sim\n";
	if (!transaction_has_changes($sim)) {
		print "No remaining full-upgrade transaction.\n";
		return 1;
	}
	my @removals = extract_removals($sim);
	if (@removals && !validate_no_boot_removals(@removals)) {
		print "Skipping full-upgrade: boot-critical package removal requires manual review.\n";
		return 1;
	}
	if (confirm('Apply the reviewed full-upgrade transaction?')) {
		must_run('apt-get', '-y', 'full-upgrade');
	} else {
		print "Skipping full-upgrade.\n";
	}
	return 1;
}

# Fully installed concrete signed/unsigned images: list of [package, version].
sub query_installed_kernel_records {
	my ($out) = cmd_capture('null', 'dpkg-query', '-W', '-f=${binary:Package}\t${Version}\t${db:Status-Abbrev}\n', 'linux-image-*');
	my @records;
	for my $line (lines_of($out)) {
		my ($pkg, $ver, $status) = split /\t/, $line, -1;
		next unless defined $status && substr($status, 1, 1) eq 'i';
		next unless $pkg =~ /\Alinux-image-[0-9]/ || $pkg =~ /\Alinux-image-unsigned-[0-9]/;
		push @records, [$pkg, $ver];
	}
	return @records;
}

sub kernel_release_for_package {
	my ($p) = @_;
	return $1 if $p =~ /\Alinux-image-unsigned-(.*)\z/;
	return $1 if $p =~ /\Alinux-image-(.*)\z/;
	return undef;
}

sub dpkg_version_gt { return cmd_run('dpkg', '--compare-versions', $_[0], 'gt', $_[1]) == 0; }

# Installed kernels sorted oldest to newest by Debian version rules: list of {package, version, release}.
sub load_installed_kernels {
	my @k = map { { package => $_->[0], version => $_->[1], release => kernel_release_for_package($_->[0]) } }
		query_installed_kernel_records();
	for my $i (0 .. $#k) {
		for my $j ($i + 1 .. $#k) {
			@k[$i, $j] = @k[$j, $i] if dpkg_version_gt($k[$i]{version}, $k[$j]{version});
		}
	}
	return @k;
}

sub boot_artifact_exists { return -r "/boot/vmlinuz-$_[0]"; }

# The keep-set: the newest $KEEP_NEWEST_KERNELS plus the running kernel. Returns
# (\@protected, \@removable), or () after an ERROR when the running kernel has no fully installed
# image or a protected kernel has no readable /boot/vmlinuz-<release>.
sub select_protected_kernels {
	my ($running, @kernels) = @_;
	my %keep;
	my $start = @kernels - $KEEP_NEWEST_KERNELS;
	$start = 0 if $start < 0;
	$keep{$kernels[$_]{package}} = 1 for $start .. $#kernels;
	my $running_found = 0;
	for my $k (@kernels) {
		if ($k->{release} eq $running) {
			$keep{$k->{package}} = 1;
			$running_found = 1;
		}
	}
	return err("Running kernel $running is not represented by a fully installed image package.") && ()
		unless $running_found;
	my (@protected, @removable);
	for my $k (@kernels) {
		if ($keep{$k->{package}}) {
			return err("Protected kernel $k->{package} has no readable /boot/vmlinuz-$k->{release}.") && ()
				unless boot_artifact_exists($k->{release});
			push @protected, $k->{package};
		} else {
			push @removable, $k->{package};
		}
	}
	return (\@protected, \@removable);
}

sub package_is_installed {
	my ($out, $rc) = cmd_capture('null', 'dpkg-query', '-W', '-f=${db:Status-Abbrev}', $_[0]);
	return $rc == 0 && length($out) >= 2 && substr($out, 1, 1) eq 'i';
}

# Exact release companions of each removable image that are installed; never guesses shared ABI headers.
sub build_kernel_purge_list {
	my (@removable) = @_;
	my (%seen, @purge);
	for my $image (@removable) {
		my $r = kernel_release_for_package($image);
		for my $c ($image, "linux-image-extra-$r", "linux-headers-$r", "linux-modules-$r", "linux-modules-extra-$r") {
			next if $seen{$c};
			if (package_is_installed($c)) {
				push @purge, $c;
				$seen{$c} = 1;
			}
		}
	}
	return @purge;
}

sub run_kernel_cleanup {
	section('Installed kernel packages');
	my $running = must_capture('uname', '-r');
	print "Running kernel: $running\n";
	my @kernels = load_installed_kernels();
	return err('No fully installed concrete kernel image packages were found.') unless @kernels;
	my ($protected, $removable) = select_protected_kernels($running, @kernels);
	return 0 unless $protected;
	print "\nProtected kernel image packages:\n";
	print "  $_\n" for @$protected;
	if (!@$removable) {
		print "No old kernel image packages are eligible for removal.\n";
		return 1;
	}
	my @purge = build_kernel_purge_list(@$removable);
	if (!@purge) {
		print "No installed kernel-related packages are eligible for purge.\n";
		return 1;
	}
	print "\nKernel-related packages proposed for purge:\n";
	print "  $_\n" for @purge;
	if (confirm('Purge the listed old kernel packages?')) {
		must_run('apt-get', '-y', 'purge', @purge);
	} else {
		print "Skipping kernel cleanup.\n";
	}
	return 1;
}

sub run_autoremove {
	section('Autoremove review');
	my $sim = must_capture('apt-get', '-s', 'autoremove', '--purge');
	print "$sim\n";
	my @removals = extract_removals($sim);
	if (!@removals) {
		print "No autoremove candidates detected.\n";
		return 1;
	}
	if (!validate_no_boot_removals(@removals)) {
		print "Skipping autoremove: boot-critical package removal requires manual review.\n";
		return 1;
	}
	if (confirm('Run the reviewed autoremove transaction?')) {
		must_run('apt-get', '-y', 'autoremove', '--purge');
	} else {
		print "Skipping autoremove.\n";
	}
	return 1;
}

# Kernels removed without purging (unattended-upgrades' old-kernel removal does this) stay in dpkg's
# `rc` state: config files and maintainer-script residue only. run_kernel_cleanup sees only `ii`
# images and autoremove purges only what it removes in that run, so these are swept here. Only exact
# `rc` status is listed; the boot-critical guard does not apply because no installed package is touched.
sub query_rc_kernel_packages {
	my ($out) = cmd_capture('null', 'dpkg-query', '-W', '-f=${binary:Package}\t${db:Status-Abbrev}\n', 'linux-image-*', 'linux-modules-*');
	my @pkgs;
	for my $line (lines_of($out)) {
		my ($pkg, $status) = split /\t/, $line, -1;
		next unless defined $status && substr($status, 0, 2) eq 'rc' && $pkg =~ /\Alinux-(?:image|modules)-/;
		$pkg =~ s/:.*//s;
		push @pkgs, $pkg;
	}
	return @pkgs;
}

sub rc_kernel_release_for_package {
	my ($p) = @_;
	for my $prefix (qw(linux-image-unsigned- linux-image-extra- linux-modules-extra- linux-modules- linux-image-)) {
		return substr($p, length $prefix) if index($p, $prefix) == 0;
	}
	return undef;
}

sub load_rc_kernel_packages {
	my ($running) = @_;
	# Defensive: never touch anything named for the running kernel.
	return grep { my $r = rc_kernel_release_for_package($_); !(defined $r && $r eq $running) } query_rc_kernel_packages();
}

sub run_rc_kernel_cleanup {
	section('Removed-but-not-purged kernel packages (rc)');
	my @rc = load_rc_kernel_packages(must_capture('uname', '-r'));
	if (!@rc) {
		print "No rc-state kernel packages found.\n";
		return 1;
	}
	printf "Kernel packages already removed, config files left behind (%d):\n", scalar @rc;
	print "  $_\n" for @rc;
	if (confirm('Purge the listed rc-state kernel packages?')) {
		must_run('dpkg', '--purge', @rc);
	} else {
		print "Skipping rc-state kernel purge.\n";
	}
	return 1;
}

sub run_apt_cache_cleanup {
	section('APT archive cleanup');
	my ($usage, $rc) = cmd_capture('merge', 'du', '-sh', $ARCHIVE_DIR);
	if ($rc != 0) {
		print "Unable to read archive footprint for $ARCHIVE_DIR; skipping cache cleanup.\n";
		return 1;
	}
	print "$usage\n";
	my $sim = must_capture('apt-get', '-s', 'autoclean');
	print "$sim\n";
	if (!archive_transaction_has_changes($sim)) {
		print "No cached .debs eligible for autoclean.\n";
	} elsif (confirm('Remove cached .debs that can no longer be downloaded?')) {
		must_run('apt-get', '-y', 'autoclean');
	} else {
		print "Skipping autoclean.\n";
	}
	# Independent of stage one: a "no" here is normal and leaves stage one's result intact.
	if (confirm('Also clear ALL cached .debs (forces re-download on next install)?')) {
		must_run('apt-get', '-y', 'clean');
	} else {
		print "Skipping full cache clear.\n";
	}
	return 1;
}

# systemd's journal is root-owned log residue, like the apt archive. `--vacuum-size` removes only
# archived journal files (never the active one), oldest first; hosts without journald skip.
sub run_journal_cleanup {
	section('Journal cleanup');
	if (!have_cmd('journalctl')) {
		print "journalctl not found; skipping journal cleanup.\n";
		return 1;
	}
	my ($usage, $rc) = cmd_capture('merge', 'journalctl', '--disk-usage');
	if ($rc != 0) {
		print "Unable to read journal disk usage; skipping journal cleanup.\n";
		return 1;
	}
	print "$usage\n";
	if (confirm("Vacuum archived journal files down to $JOURNAL_VACUUM_SIZE?")) {
		must_run('journalctl', "--vacuum-size=$JOURNAL_VACUUM_SIZE");
	} else {
		print "Skipping journal cleanup.\n";
	}
	return 1;
}

# ---- non-interactive posture report -----------------------------------------
# The read-only sibling of the interactive flow: no root, no TTY, no `apt-get update`, no mutation.
# stdout carries one JSON object and nothing else.

sub newest_mtime {
	my ($dir) = @_;
	my $newest = 0;
	opendir(my $dh, $dir) or return 0;
	my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
	closedir($dh);
	for my $e (@entries) {
		my $path = "$dir/$e";
		my @st = lstat($path) or next;
		my $m = int($st[9]);
		$newest = $m if $m > $newest;
		if (-d _) {
			my $sub = newest_mtime($path);
			$newest = $sub if $sub > $newest;
		}
	}
	return $newest;
}

# Newest mtime under the apt lists directory, as an age; -1 when unreadable, absent or empty.
sub index_age_seconds {
	my $newest = -r $APT_LISTS_DIR ? newest_mtime($APT_LISTS_DIR) : 0;
	return -1 if $newest <= 0;
	return time() - $newest;
}

sub run_report {
	my ($host, $hrc) = cmd_capture('null', 'hostname');
	($host) = cmd_capture('null', 'uname', '-n') if $hrc != 0 || $host eq '';
	my $age = index_age_seconds();
	# The `Listing...` banner apt prints is dropped explicitly; every remaining line is one package.
	my ($list) = cmd_capture('null', 'apt', 'list', '--upgradable');
	my @upgradable = grep { !/^Listing/ } lines_of($list);
	my $security = grep { /-security/ } @upgradable;
	my ($sim) = cmd_capture('null', 'apt-get', '-s', 'autoremove');
	my @removals = extract_removals($sim);
	my @rc = query_rc_kernel_packages();
	my $reboot = -e $REBOOT_REQUIRED_FILE ? 'true' : 'false';
	my $json = JSON::PP->new->allow_nonref;
	printf "{\"host\":%s,\"indexAgeSeconds\":%d,\"upgradable\":%d,\"securityUpgradable\":%d,\"autoremovable\":%d,\"rcKernels\":%d,\"rebootRequired\":%s}\n",
		$json->encode($host), $age, scalar @upgradable, $security, scalar @removals, scalar @rc, $reboot;
	return 1;
}

sub usage_error { die_exit(2, 'usage: ' . program_name() . ' [--report]'); }

sub main {
	my @args = @_;
	$| = 1;
	$ENV{DEBIAN_FRONTEND} = q(readline);
	for my $a (@args) {
		if ($a eq '--help' || $a eq '-h') {
			my $name = program_name();
			$name =~ s{.*/}{};
			print "usage: $name [--report]\n";
			print "Interactive APT maintenance (root, TTY); --report prints a read-only JSON posture report.\n";
			return 0;
		}
	}
	usage_error() if @args > 1;
	if (@args == 1) {
		usage_error() unless $args[0] eq '--report';
		run_report();
		return 0;
	}
	require_root(@args);
	require_tty();

	section('APT update');
	must_run('apt-get', 'update');
	run_upgrade();
	must_run('apt-get', 'check');
	run_full_upgrade();
	must_run('apt-get', 'check');
	run_kernel_cleanup() or exit 1;
	run_autoremove();
	run_rc_kernel_cleanup();
	run_apt_cache_cleanup();
	run_journal_cleanup();
	section('Done');
	return 0;
}

exit(main(@ARGV)) unless caller;
1;
