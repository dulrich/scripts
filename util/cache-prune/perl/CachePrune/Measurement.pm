# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/
#
# CachePrune::Measurement: the one measurement result type shared by every size hook, the one
# helper that decides whether two of them may be subtracted, and byte rendering. perl-base only.
#
# THE PROBE RECORD -- a perl hashref with three named fields:
#
#     { total => BYTES, reclaimable => BYTES, source => TOKEN | undef }
#
#   total        non-negative integer (0 when unavailable)
#   reclaimable  non-negative integer (0 when unavailable)
#   source       provenance token, no whitespace, never empty; undef when unavailable --
#                availability is implied by a defined source, there is no separate flag
#
# The unavailable record is one shared constant hashref (probe_unavailable); it is read-only in
# spirit and never mutated. A size hook returns exactly one record (built with probe_available /
# probe_unavailable) and prints nothing. Anything else -- a string, a bare pair, junk, '' -- fails
# probe_is_record, the one shape check (applied by Main at the hook boundary), so a regressed
# hook can never arithmetic its way to a silent 0.
package CachePrune::Measurement;
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(probe_available probe_unavailable probe_is_record probe_is_available
	probe_compare human_bytes human_bytes_signed);

my $UNAVAILABLE = { total => 0, reclaimable => 0, source => undef };

# probe_available($total, $reclaimable, $source): fails closed to the unavailable record when the
# source is empty or contains whitespace -- an anonymous measurement must never reach a delta.
# The byte figures are integer-coerced as sprintf %d does.
sub probe_available {
	my ($total, $reclaimable, $source) = @_;
	return $UNAVAILABLE unless defined $source && length $source && $source !~ /\s/;
	return { total => 0 + sprintf('%d', $total // 0), reclaimable => 0 + sprintf('%d', $reclaimable // 0),
		source => $source };
}

sub probe_unavailable { return $UNAVAILABLE; }

# probe_is_record($r): the one shape check -- a hashref whose total/reclaimable are non-negative
# integers and whose source is undef (unavailable, then both figures 0) or a whitespace-free token.
sub probe_is_record {
	my ($r) = @_;
	return 0 unless ref $r eq 'HASH';
	for my $k (qw(total reclaimable)) {
		return 0 unless defined $r->{$k} && $r->{$k} =~ /\A[0-9]+\z/;
	}
	my $s = $r->{source};
	unless (defined $s) { return $r->{total} == 0 && $r->{reclaimable} == 0 ? 1 : 0; }
	return $s =~ /\A\S+\z/ ? 1 : 0;
}

sub probe_is_available {
	my ($r) = @_;
	return (probe_is_record($r) && defined $r->{source}) ? 1 : 0;
}

# probe_compare($name, $before, $after): the single owner of delta eligibility and signed
# subtraction. Returns ($signed_delta) when both records are available and carry the same
# source, else (undef, $reason). Before/after from different sources are never subtracted, for
# every runtime.
sub probe_compare {
	my ($name, $before, $after) = @_;
	return (undef, 'the pre-action size probe failed') unless probe_is_available($before);
	return (undef, 'the post-action size probe failed') unless probe_is_available($after);
	my ($bs, $as) = ($before->{source}, $after->{source});
	return (undef, "$name size source changed between probes: $bs -> $as") if $bs ne $as;
	return ($before->{total} - $after->{total});
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
