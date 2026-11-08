#!/usr/bin/perl
# docker-residue.pl: the CLI over the JSON half of docker-residue.sh (capture shaping,
# classifier, footprint sum), in perl + JSON::PP so cache-prune needs no jq. A thin wrapper:
# the logic lives in perl/CachePrune/DockerResidue.pm, which the perl cache-prune calls
# in-process. Not a util subcommand: it sits under util/cache-prune/, which the router
# never lists. Invoked as `perl docker-residue.pl <mode> [args]`; reads stdin.
#
# Modes:
#   capture <repo-root>     runs the docker / compose subprocesses itself and prints
#                           the capture document (see docker-residue.sh); no JSON
#                           passes through argv or the shell
#   classify                stdin: capture JSON -> TSV rows (see docker-residue.sh)
#   footprint               stdin: `system df` JSON lines -> bytes, exit 1 if incomplete
#
# hbytes (in the module) and docker_size_to_bytes (runtimes/docker.sh, bash, so the
# docker build-cache probe needs no perl) are one contract: the shared vector
# table in util/tests/cache-prune/adapters.sh asserts both.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
use strict;
use warnings;
use Cwd ();
use File::Basename ();
use lib File::Basename::dirname(Cwd::realpath(__FILE__)) . '/perl';
use JSON::PP ();
use CachePrune::DockerResidue ();

my $mode = shift @ARGV // '';
binmode STDOUT;

if ($mode eq 'capture') {
    print CachePrune::DockerResidue::capture(shift @ARGV);
} elsif ($mode eq 'classify') {
    print "$_\n" for CachePrune::DockerResidue::classify_text(CachePrune::DockerResidue::slurp());
} elsif ($mode eq 'footprint') {
    my $sum = CachePrune::DockerResidue::footprint(CachePrune::DockerResidue::slurp());
    exit 1 unless defined $sum;
    print "$sum\n";
} elsif ($mode eq "--help" || $mode eq "-h") {
    print "usage: perl docker-residue.pl <mode> [args]  (modes: capture, classify, footprint)\n";
} else {
    print STDERR "usage: perl docker-residue.pl <mode> [args]  (modes: capture, classify, footprint)\n";
    exit 2;
}
