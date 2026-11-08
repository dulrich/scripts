# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# CachePrune::Measurement: the one measurement result type shared by every size hook, the one
# helper that decides whether two of them may be subtracted, and byte rendering. perl-base only.
#
# THE PROBE RECORD -- a string of four single-space-separated fields in this fixed order:
#
#     <status> <total_bytes> <reclaimable_bytes> <source>
#
#   status             "available" or "unavailable"
#   total_bytes        non-negative decimal integer (0 when unavailable)
#   reclaimable_bytes  non-negative decimal integer (0 when unavailable)
#   source             provenance token, no whitespace, never empty; "-" when unavailable
#
# A size hook returns exactly one record (built with probe_available / probe_unavailable) and
# prints nothing. Anything else -- a bare pair, junk, '' -- is rejected by probe_is_valid, so a
# regressed hook can never arithmetic its way to a silent 0.
package CachePrune::Measurement;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(probe_available probe_unavailable probe_is_valid probe_is_available
	probe_fields probe_compare human_bytes human_bytes_signed);

use constant UNAVAILABLE => 'unavailable 0 0 -';

# probe_available($total, $reclaimable, $source): fails closed to the unavailable record when the
# source is empty or contains whitespace -- an anonymous measurement must never reach a delta.
sub probe_available {
	my ($total, $reclaimable, $source) = @_;
	return UNAVAILABLE unless defined $source && length $source && $source !~ /\s/;
	return sprintf('available %d %d %s', $total // 0, $reclaimable // 0, $source);
}

sub probe_unavailable { return UNAVAILABLE; }

sub probe_is_valid {
	my ($r) = @_;
	return 0 unless defined $r;
	return 1 if $r eq UNAVAILABLE;
	return $r =~ /\Aavailable [0-9]+ [0-9]+ \S+\z/ ? 1 : 0;
}

sub probe_is_available {
	my ($r) = @_;
	return (probe_is_valid($r) && $r =~ /\Aavailable /) ? 1 : 0;
}

# probe_fields($record): (status, total, reclaimable, source) of a valid record.
sub probe_fields { return split / /, $_[0], 4; }

# probe_compare($name, $before, $after): the single owner of delta eligibility and signed
# subtraction. Returns "available <signed_delta>" when both records are available and carry the
# same source, else "unavailable <reason>". Before/after from different sources are never
# subtracted, for every runtime.
sub probe_compare {
	my ($name, $before, $after) = @_;
	return 'unavailable the pre-action size probe failed' unless probe_is_available($before);
	return 'unavailable the post-action size probe failed' unless probe_is_available($after);
	my (undef, $bt, undef, $bs) = probe_fields($before);
	my (undef, $at, undef, $as) = probe_fields($after);
	if ($bs ne $as) {
		return "unavailable $name size source changed between probes: $bs -> $as";
	}
	return 'available ' . ($bt - $at);
}

# human_bytes($bytes): "%.1f<unit>" with 1024 steps, B..PB (bash human_bytes).
sub human_bytes {
	my ($n) = @_;
	my @u = qw(B KB MB GB TB PB);
	my $i = 0;
	while ($n >= 1024 && $i < 5) { $n /= 1024; $i++; }
	return sprintf('%.1f%s', $n, $u[$i]);
}

# human_bytes_signed($bytes): human_bytes of the magnitude, sign reattached.
sub human_bytes_signed {
	my ($n) = @_;
	return $n < 0 ? '-' . human_bytes(-$n) : human_bytes($n);
}

1;
