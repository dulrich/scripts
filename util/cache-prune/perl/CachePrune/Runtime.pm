# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
package CachePrune::Runtime;
use strict;
use warnings;

our @ORDER;      # registered runtime hashrefs, in run order
our %BY_NAME;    # name -> runtime hashref
# Help fragments, printed verbatim by usage() at fixed slots (see POD).
our %HELP = map { $_ => [] } qw(runtimes env core_runtimes core_env_lead core_env
	core_verbs core_residue core_options core_notes_safe core_notes_purge core_notes_delta
	core_env_residue core_purge_caveat);
# Core load order: core runtimes/*.pm named here load first, in this order (the bash
# RUNTIME_ORDER core order); any other core module follows, sorted.
our @CORE_ORDER = qw(uv npm docker pip bun cargo trash);

my %HOOKS = map { $_ => 1 } qw(detect absent cache_dir size prune purge purge_prompt
	safe_reclaimable detail residue);
my %DATA = map { $_ => 1 } qw(name after predicts report_notes interactive_only help state);
my %HELP_SLOTS = map { $_ => 1 } keys %HELP;

sub reset_registry { @ORDER = (); %BY_NAME = (); $HELP{$_} = [] for keys %HELP; }

sub register_runtime {
	my ($spec) = @_;
	die "register_runtime: a hashref spec is required\n" unless ref $spec eq 'HASH';
	my $name = $spec->{name};
	die "register_runtime: name must be a non-empty token\n"
		unless defined $name && $name =~ /\A[A-Za-z0-9_.-]+\z/;
	die "register_runtime: $name is already registered\n" if $BY_NAME{$name};
	die "register_runtime: $name needs a detect hook\n" unless ref $spec->{detect} eq 'CODE';
	die "register_runtime: $name needs a size hook\n" unless ref $spec->{size} eq 'CODE';
	for my $k (keys %$spec) {
		die "register_runtime: $name: unknown key '$k'\n" unless $HOOKS{$k} || $DATA{$k};
		die "register_runtime: $name: '$k' must be a code ref\n"
			if $HOOKS{$k} && defined $spec->{$k} && ref $spec->{$k} ne 'CODE';
	}
	my $predicts = $spec->{predicts} // ($spec->{purge} ? 'purge' : $spec->{prune} ? 'safe' : undef);
	if (defined $predicts) {
		die "register_runtime: $name: predicts must be 'purge' or 'safe'\n"
			unless $predicts eq 'purge' || $predicts eq 'safe';
		my $verb = $predicts eq 'safe' ? 'prune' : 'purge';
		die "register_runtime: $name: predicts '$predicts' needs a $verb hook\n"
			unless ref $spec->{$verb} eq 'CODE';
	}
	die "register_runtime: $name: report_notes must be an array ref\n"
		if defined $spec->{report_notes} && ref $spec->{report_notes} ne 'ARRAY';
	my %rt = %$spec;
	$rt{predicts} = $predicts;
	$rt{state} = {} unless ref $rt{state} eq 'HASH';
	my $help = delete $rt{help} // {};
	for my $slot (sort keys %$help) {
		die "register_runtime: $name: unknown help slot '$slot'\n" unless $HELP_SLOTS{$slot};
		push @{ $HELP{$slot} }, ref $help->{$slot} eq 'ARRAY' ? @{ $help->{$slot} } : $help->{$slot};
	}
	my $rt = \%rt;
	my $after = $rt{after};
	my $placed = 0;
	if (defined $after && length $after) {
		for my $i (0 .. $#ORDER) {
			if ($ORDER[$i]{name} eq $after) { splice @ORDER, $i + 1, 0, $rt; $placed = 1; last; }
		}
	}
	push @ORDER, $rt unless $placed;
	$BY_NAME{$name} = $rt;
	return $rt;
}

# load_module($file): compile one runtime module (it registers itself as a side effect).
sub load_module {
	my ($file) = @_;
	die "cache-prune: cannot read $file\n" unless -r $file;
	do $file;
	die "cache-prune: failed to load $file: $@" if $@;
	return 1;
}

# load_core($dir): runtimes/*.pm, @CORE_ORDER first, then the rest sorted.
sub load_core {
	my ($dir) = @_;
	my %have = map { (m{([^/]+)\.pm\z})[0] => $_ } glob("$dir/*.pm");
	my @files = map { delete $have{$_} } grep { $have{$_} } @CORE_ORDER;
	push @files, map { $have{$_} } sort keys %have;
	load_module($_) for @files;
}

# load_fleet($dir): every regular *.pm in $dir, sorted; anything else (the overlay's bash
# *.sh modules) is ignored silently; an absent dir loads nothing.
sub load_fleet {
	my ($dir) = @_;
	return unless defined $dir && length $dir && -d $dir;
	load_module($_) for grep { -f $_ } sort glob("$dir/*.pm");
}

1;

__END__

=head1 NAME

CachePrune::Runtime - the cache-prune runtime registry and the runtime module interface

=head1 SYNOPSIS

A runtime module is a perl file F<< <name>.pm >> in F<util/cache-prune/perl/runtimes/> (core)
or in the fleet directory C<$CACHE_PRUNE_FLEET_DIR> (default
F<< <repo>/private/util/cache-prune/fleet >>). It is loaded with C<do FILE> (it need not declare
a package or return true, but should use its own package for its subs) and registers itself:

    package CachePrune::Runtime::example;
    use strict;
    use warnings;
    use CachePrune::Core ();
    use CachePrune::Adapters ();

    CachePrune::Runtime::register_runtime({
        name      => 'example',
        after     => 'cargo',                       # optional slot
        detect    => sub { CachePrune::Core::have_cmd('example') },
        absent    => sub { "no example on host" },
        cache_dir => sub { (0, "$ENV{HOME}/.example") },
        size      => \&CachePrune::Adapters::generic_size,
        purge     => sub { CachePrune::Core::cmd_run('example', 'clean') == 0 },
        help      => { runtimes => ["The example runtime ...\n"] },
    });

=head1 DISCOVERY AND ORDER

C<cache-prune.pl> loads, in this order: the core modules in F<perl/runtimes/> -- those named
in C<@CachePrune::Runtime::CORE_ORDER> (C<uv npm docker pip bun cargo trash>, the bash core
order) first, in that order, then any other core F<*.pm> sorted by name -- and then every
regular F<*.pm> in the fleet directory, sorted by name. Only F<*.pm> files are loaded from the
fleet directory; anything else there (the overlay's bash F<*.sh> modules) is ignored silently,
and an absent directory, or one without F<*.pm>, leaves the tool unchanged. A module that fails
to compile aborts the run (the bash tool's C<source> under C<set -e> behaves the same).

Run order is registration order: C<register_runtime> appends, or inserts right after the
runtime named by C<after> when that one is already registered (an unknown C<after> appends).
So a fleet module naming C<< after => 'cargo' >> (codex) lands right after cargo, ahead of
trash, and a module naming another fleet module (C<< after => 'repo' >>) must sort after it.

=head1 register_runtime(\%spec)

Returns the stored runtime hashref (C<$rt>). Dies on a missing/duplicate C<name>, a missing
C<detect> or C<size>, a hook that is not a code ref, an unknown key or an unknown help slot.

Every hook is called with the runtime hashref C<$rt> as its first argument. C<< $rt->{name} >>
is the name; C<< $rt->{state} >> is a hashref private to the module (initialised to C<{}>) --
the place for scan results a size hook leaves for C<detail>, C<purge_prompt>,
C<safe_reclaimable> and the verbs (the bash modules' scan globals). Run state is read from
C<CachePrune::Core>: C<$MODE> (C<report>/C<yes>/C<interactive>), C<$INCLUDE_PURGE>,
C<$DOCKER_UNTIL>. Hooks that print write to STDOUT; warnings go through
C<CachePrune::Core::warn_msg> (C<WARNING: ...> on STDERR).

=head2 Required

=over

=item name => STRING

Token C<[A-Za-z0-9_.-]+>; the section header and every message use it.

=item detect => sub($rt) -> BOOL

Silent predicate: is the runtime present? False prints C<skip: NAME: REASON> (see C<absent>)
and never fails the run.

=item size => sub($rt, $cache_dir) -> RECORD | undef

Returns one probe record, a hashref (L<CachePrune::Measurement>; build it with C<probe_available> /
C<probe_unavailable>) and prints nothing. C<$cache_dir> is C<cache_dir>'s result, or C<''>
when there is no C<cache_dir> hook. C<undef> means the probe itself failed
(C<WARNING: NAME: failed to determine cache size>, C<$FAILED> set); any other non-record
(a string, C<''>, a bare pair, junk) is C<WARNING: NAME: cache size probe returned a malformed result>,
C<$FAILED> set. An unavailable record prints C<NAME cache size: unavailable> and skips every
action. The size hook runs once before acting and once after any verb ran; the two records are
compared by C<probe_compare>, so a hook that can measure from more than one source must name
the source in the record -- a before/after pair from different sources reports the delta as
unavailable. The census helper C<CachePrune::Adapters::generic_size> is a ready-made size hook
(source C<census>).

=back

=head2 Optional hooks

=over

=item absent => sub($rt) -> STRING

The skip reason when C<detect> is false: C<no TOOL on host> for a missing executable, or a
distinct cause. Absent hook or empty string reads C<not detected>.

=item cache_dir => sub($rt) -> (STATUS, DIR)

STATUS 0 with the cache directory; 2 = unresolvable (prints C<skip: NAME cache location
unresolved>, not a failure); anything else = hard failure (C<WARNING: NAME: failed to resolve
cache location>, C<$FAILED> set). No hook: C<$cache_dir> is C<''> (daemon-owned or
multi-directory caches).

=item prune => sub($rt) -> BOOL

The safe verb. Its presence makes the runtime safe tier. True = success. Elected by C<--yes>,
or an interactive C<Prune NAME cache?> confirm.

=item purge => sub($rt) -> BOOL

The destructive purge verb; its presence makes the runtime purge tier. True = success. With a
C<prune> hook too (dual verb) it is elected only with C<--include-purge> (C<--yes> runs it
instead of the safe verb; interactively it is a second confirm after the safe one); without
one (purge-only) C<--yes> needs C<--include-purge> and interactive mode confirms it
unconditionally. A verb that deletes files itself must pass every path through
C<CachePrune::Actions::guarded_remove> and its guards; a guarded skip warns and still returns
true (a skip is not a verb failure). A false return prints C<WARNING: NAME: prune failed>,
sets C<$FAILED>, is still measured (C<-- partial result>), and fails the runtime.

=item purge_prompt => sub($rt) -> STRING

Interactive purge confirm text in place of C<Purge NAME cache? (opt-in, destructive)>; called
only when it can be shown (interactive mode), after the size hook.

=item safe_reclaimable => sub($rt) -> BYTES

Split tier, for a dual-verb runtime whose probe predicts both verbs: the record's reclaimable
is the purge figure, this the safe verb's bytes (a subset; read from C<state>, never a
re-scan; clamped to the purge figure). Both lines are printed and the overlap is counted for
the Total block.

=item detail => sub($rt)

Prints a per-runtime breakdown right after the size lines (only when the record is
available).

=item residue => sub($rt) -> BOOL

A separate step run after the verbs and their delta line, outside C<--report>, when the record
was available. Prints its own measured delta; returns true when it removed anything (counts as
acted, suppressing C<NAME: skipped.>).

=back

=head2 Optional data

=over

=item after => NAME

Registration slot (see L</DISCOVERY AND ORDER>).

=item interactive_only => STRING

Purge-tier data never elected under C<--yes>, whatever C<--include-purge> says; the string is
the note printed under C<--yes>. The report gate reads C<emptied only after an interactive
confirm, never under --yes>.

=item predicts => 'purge' | 'safe'

Which verb the size record's reclaimable figure predicts. Default C<purge> when the runtime has a
C<purge> hook, else C<safe> when it has a C<prune> hook; the named verb's hook must exist, and
any other value is rejected at registration. A dual-verb runtime whose probe predicts the safe
verb only declares C<safe> (its purge reach then belongs in C<report_notes>). A
C<safe_reclaimable> hook implies both figures, whatever C<predicts> says.

=item report_notes => [STRING, ...]

Notes printed verbatim, one per line, after the reclaimable lines, in list order.

=item help => { SLOT => STRING | [STRING, ...] }

Help fragments, each printed verbatim followed by a newline. Slots, in usage() order:
C<runtimes> (fleet runtime text) and C<core_runtimes> before the C<Notes:> block;
C<core_env_lead> first under C<Honoured environment:>, before the shared
C<CACHE_PRUNE_REPO_ROOT> entry; then C<env> (fleet) and C<core_env> after it. Fragments of
one slot print in registration order. The core runtimes add C<core_verbs> (the verb paragraphs), C<core_residue> (the docker residue section) and C<core_options> (option entries, before C<-h, --help>) in the preamble, C<core_notes_safe>, C<core_notes_purge> and C<core_notes_delta> in the C<Notes:> block, and C<core_env_residue> after C<core_env_lead>. C<core_purge_caveat> is inline: its fragments (no trailing newline, no leading text) are joined with C<; > and spliced into the C<--yes --include-purge> mode entry, after C<(their only verb;>. A fragment naming a default path stays generic
(C<< <repo>/private/... >>).

=item state => HASHREF

Initial module state (default C<{}>).

=back

=head2 Tier membership

Tier follows from hook membership alone: safe tier iff C<prune>, purge tier iff C<purge>
(uv/npm carry both); with neither, the bytes count toward the total only. Report lines, per
kind: both verbs with C<safe_reclaimable> -- the safe and purge lines; a predicted purge verb
(C<predicts> C<purge>) -- the purge line, plus C<note: NAME's safe verb cannot be predicted ...>
when a C<prune> hook exists too; a predicted safe verb (C<predicts> C<safe>) -- the safe line.
C<report_notes> follow. C<interactive_only> only changes the purge line's gate text and the
election rule.

=head1 SHARED HELPERS FOR MODULES

C<CachePrune::Core>: C<cmd_capture([\%o,] @cmd)> -> (stdout, status), C<cmd_run([\%o,] @cmd)>
-> status (options C<< dir => DIR >>, C<< stdin => 'null' >>, C<< stderr => 'null' >>), C<have_cmd(NAME)>,
C<confirm(PROMPT)>, C<warn_msg(@words)>, C<docker_window_seconds(W)>; always call them fully
qualified (the test seam replaces the globs). C<CachePrune::Measurement>: C<probe_available>,
C<probe_unavailable>, C<probe_is_available>, C<probe_compare>,
C<human_bytes>, C<human_bytes_signed>. C<CachePrune::Adapters>: C<dir_census_bytes(DIR)> ->
(total, reclaimable), C<generic_size>, C<path_du_bytes(PATH)>. C<CachePrune::Actions>:
C<tier_elected(KIND, PROMPT, NOTE)> (kinds C<safe purge optin item>), C<guarded_remove(ROOT_REAL,
PATH)> -> (code 0/1/2/3, candidate), C<realpath_e>, C<path_contained(PATH, EXPECTED_REAL)>,
C<path_on_noatime_mount(PATH, MOUNTS_FILE)>, C<path_git_tracked(DIR)>,
C<outermost_marker_dirs(ROOT, VALIDATOR|undef, MATCH)> with C<< MATCH->($path, $basename) >>,
C<env_days(VALUE, DEFAULT)>.

=cut
