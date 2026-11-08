#!/usr/bin/perl
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# cache-prune.pl: report and (optionally) prune rebuildable language-runtime caches for the
# invoking user -- the perl port of util/cache-prune.sh, side by side with it until the
# cutover. Not a router subcommand (mode 644): run as `perl util/cache-prune/perl/cache-prune.pl
# [--report | --yes [--include-purge]] [--docker-until <window>] [-h|--help]`.
#
# Layout (beside this file, found via its own real path):
#   CachePrune/Core.pm         run state, output helpers, command seam
#   CachePrune/Measurement.pm  the probe-record type, probe_compare, human_bytes
#   CachePrune/Adapters.pm     hardlink-aware census and du probes
#   CachePrune/Actions.pm      election rules, verb execution, guarded removal helpers
#   CachePrune/Runtime.pm      the runtime registry; its POD is the module interface
#   CachePrune/Main.pm         CLI, lifecycle, usage, Total block
#   runtimes/*.pm              one self-registering module per core runtime
# Fleet modules: every *.pm in $CACHE_PRUNE_FLEET_DIR (default
# <repo>/private/util/cache-prune/fleet), loaded after the core runtimes.
#
# Loaded with `require` (tests) it loads the modules and defines cache_prune_load only; main
# runs when it is the program. perl-base + JSON::PP only.
use strict;
use warnings;
use Cwd ();
use File::Basename ();

our $CACHE_PRUNE_PERL;
BEGIN { $CACHE_PRUNE_PERL = File::Basename::dirname(Cwd::realpath(__FILE__)); }
use lib $CACHE_PRUNE_PERL;
use CachePrune::Main ();

# cache_prune_load(): register the core runtimes, then the fleet modules.
sub cache_prune_load {
	CachePrune::Runtime::load_core("$CACHE_PRUNE_PERL/runtimes");
	my $fleet = $ENV{CACHE_PRUNE_FLEET_DIR};
	$fleet = "$CACHE_PRUNE_PERL/../../../private/util/cache-prune/fleet"
		unless defined $fleet && length $fleet;
	$fleet = Cwd::realpath($fleet) // $fleet if -d $fleet;
	CachePrune::Runtime::load_fleet($fleet);
}

unless (caller) {
	$| = 1;
	cache_prune_load();
	exit CachePrune::Main::main(@ARGV);
}

1;
