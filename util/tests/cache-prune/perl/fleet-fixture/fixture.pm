# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# Fixture fleet module for util/tests/cache-prune/perl/: loaded through CACHE_PRUNE_FLEET_DIR
# to prove overlay registration, `after` slotting and help-fragment slots. Two runtimes:
# fixslot (after cargo, purge-only, census of $CACHE_PRUNE_FIXTURE_DIR) and fixtail (appended,
# detect false, its own absent reason).
package CachePrune::Runtime::fixture;
use strict;
use warnings;
use CachePrune::Core ();
use CachePrune::Adapters ();
use CachePrune::Measurement ();
use CachePrune::Runtime ();

CachePrune::Runtime::register_runtime({
	name => 'fixtail',
	detect => sub { 0 },
	absent => sub { 'fixture tail never present' },
	size => sub { CachePrune::Measurement::probe_unavailable() },
	help => { env => '  CACHE_PRUNE_FIXTURE_DIR (fixture)' },
});

CachePrune::Runtime::register_runtime({
	name => 'fixslot',
	after => 'cargo',
	detect => sub { defined $ENV{CACHE_PRUNE_FIXTURE_DIR} && -d $ENV{CACHE_PRUNE_FIXTURE_DIR} },
	cache_dir => sub { (0, $ENV{CACHE_PRUNE_FIXTURE_DIR}) },
	size => \&CachePrune::Adapters::generic_size,
	purge => sub { 1 },
	detail => sub { print "fixslot detail: state=$_[0]{state}{probe}\n" },
	state => { probe => 'fixture' },
	help => { runtimes => "The fixslot runtime is a test fixture.\n" },
});

1;
