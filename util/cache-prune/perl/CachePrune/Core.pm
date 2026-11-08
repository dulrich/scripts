# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# CachePrune::Core: run state, user-facing output helpers and the command seam shared by the
# cache-prune perl core and every runtime module. perl-base only.
#
# Every external command a module runs goes through cmd_capture / cmd_run / have_cmd, and every
# prompt through confirm -- the seams the unit tests replace. Call them fully qualified
# (CachePrune::Core::cmd_run(...)), never imported, so a replaced glob is seen everywhere.
package CachePrune::Core;
use strict;
use warnings;

# Run state, reset by CachePrune::Main::main and read by the election rules and modules.
our $MODE = 'interactive';    # 'report' | 'yes' | 'interactive'
our $INCLUDE_PURGE = 0;       # --include-purge
our $DOCKER_UNTIL = '';       # validated --docker-until window ('' = no filter)
our $FAILED = 0;              # aggregate exit flag (1 => exit status 1)

# ---- output -----------------------------------------------------------------

sub section { print "\n==== $_[0] ====\n"; }

# warn_msg(@words): "WARNING: <words>" on stderr (bash warn).
sub warn_msg { print STDERR 'WARNING: ' . join(' ', @_) . "\n"; }

# die_msg(@words): "ERROR: <words>" on stderr (bash die); returns false.
sub die_msg { print STDERR 'ERROR: ' . join(' ', @_) . "\n"; return 0; }

# confirm($prompt): "<prompt> [y/N] " (shown only when stdin is a terminal, like read -p);
# y/Y/yes/YES accepts, anything else -- EOF included -- declines.
sub confirm {
	my ($prompt) = @_;
	$prompt = 'Continue?' unless defined $prompt && length $prompt;
	print STDERR "$prompt [y/N] " if -t STDIN;
	my $reply = <STDIN>;
	return 0 unless defined $reply;
	$reply =~ s/\n\z//;
	return $reply =~ /\A(?:y|Y|yes|YES)\z/ ? 1 : 0;
}

# ---- command seam -------------------------------------------------------------

sub _status { my ($w) = @_; return $w == -1 ? 127 : ($w & 127 ? 128 + ($w & 127) : $w >> 8); }

# Optional leading hashref of options for both runners: { dir => <chdir first>,
# stderr => 'keep' (default) | 'null' }.

# cmd_capture([\%opts,] @cmd): run @cmd, return (stdout with trailing newlines stripped, exit
# status); stderr is inherited. A command that cannot be executed returns status 127.
sub cmd_capture {
	my @cmd = @_;
	my %o = ref $cmd[0] eq q(HASH) ? %{ shift @cmd } : ();
	STDOUT->flush; STDERR->flush;
	my $pid = open(my $fh, '-|');
	return ('', 127) unless defined $pid;
	if ($pid == 0) {
		open(STDERR, '>', '/dev/null') if ($o{stderr} // '') eq 'null';
		if (defined $o{dir}) { chdir $o{dir} or exit 127; }
		{ no warnings 'exec'; exec { $cmd[0] } @cmd; }
		exit 127;
	}
	local $/;
	my $out = <$fh>;
	$out = '' unless defined $out;
	close($fh);
	my $rc = _status($?);
	$out =~ s/\n+\z//;
	return ($out, $rc);
}

# cmd_run([\%opts,] @cmd): run @cmd with stdout/stderr inherited; return its exit status.
sub cmd_run {
	my @cmd = @_;
	my %o = ref $cmd[0] eq q(HASH) ? %{ shift @cmd } : ();
	STDOUT->flush; STDERR->flush;
	my $pid = fork;
	return 127 unless defined $pid;
	if ($pid == 0) {
		open(STDERR, '>', '/dev/null') if ($o{stderr} // '') eq 'null';
		if (defined $o{dir}) { chdir $o{dir} or exit 127; }
		{ no warnings 'exec'; exec { $cmd[0] } @cmd; }
		exit 127;
	}
	waitpid($pid, 0);
	return _status($?);
}

# have_cmd($name): an executable $name resolves on PATH (bash `command -v`); a name with a slash
# is checked directly.
sub have_cmd {
	my ($name) = @_;
	return 0 unless defined $name && length $name;
	return (-f $name && -x _) ? 1 : 0 if $name =~ m{/};
	for my $dir (split /:/, ($ENV{PATH} // ''), -1) {
		my $p = (length $dir ? $dir : '.') . "/$name";
		return 1 if -f $p && -x _;
	}
	return 0;
}

# ---- shared parsing -------------------------------------------------------------

# docker_window_seconds($window): "<number><s|m|h|d|w>" in seconds, or undef.
sub docker_window_seconds {
	my ($w) = @_;
	return undef unless defined $w && $w =~ /\A([0-9]+)([smhdw])\z/;
	my %mul = (s => 1, m => 60, h => 3600, d => 86400, w => 604800);
	return $1 * $mul{$2};
}

1;
