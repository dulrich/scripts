# shellcheck shell=bash

# measurement.sh: the one measurement result type shared by every cache-prune
# size adapter, plus the one helper that decides whether two of them may be
# subtracted. Sourced by ../cache-prune.sh; not a util subcommand.
#
# THE PROBE RECORD -- one transport, one line on stdout, four whitespace-
# separated fields in this fixed order:
#
#     <status> <total_bytes> <reclaimable_bytes> <source>
#
#   status            "available" or "unavailable"
#   total_bytes       non-negative decimal integer (0 when unavailable)
#   reclaimable_bytes non-negative decimal integer (0 when unavailable)
#   source            provenance token, no whitespace, always non-empty;
#                     literally "-" when unavailable
#
# Everything an adapter learned about a cache travels together, through the
# adapter's stdout, and nowhere else. That is the whole point: the previous
# design returned the two byte counts on stdout and smuggled the source
# identity out through a module-level scratch-file path, because an adapter
# runs inside the subshell a command substitution forks and a plain variable
# assignment made there does not survive. When creating that temporary file
# failed, its path silently became "", both source labels read back empty,
# the "did the source change?" guard compared "" with "" and passed, and a
# system-df reading minus a buildx-du reading was reported as a 600-byte
# measurement (F9, reviews/2026-09-07-tn-code-review.md). One transport
# cannot half-arrive: a record either carries its provenance or is not a
# valid record. The regression is pinned in
# util/tests/cache-prune/measurement.sh.
#
# CC0: This work has been marked as dedicated to the public domain.
# https://creativecommons.org/publicdomain/zero/1.0/

# probe_available: build an available record. Fails closed -- a caller that
# cannot name its source gets an unavailable record, never an available one
# with empty provenance, because an anonymous measurement is exactly what
# must never reach the delta comparison below.
probe_available() {
    local total="$1"
    local reclaimable="$2"
    local source_id="$3"

    if [[ -z "$source_id" || "$source_id" =~ [[:space:]] ]]; then
        probe_unavailable
        return 0
    fi

    printf 'available %d %d %s\n' "$total" "$reclaimable" "$source_id"
}

# probe_unavailable: the canonical unavailable record. The byte fields are
# zeroed and the source is "-" so that every record has the same shape and
# one regex validates both states.
probe_unavailable() {
    printf 'unavailable 0 0 -\n'
}

# probe_is_valid: the seam contract. Anything that is not exactly one of the
# two record shapes -- a bare pair from a regressed adapter, an empty string
# from a probe that died, junk -- is rejected here, so it can never be read
# with `read -r total reclaimable` and have a missing field arithmetic its way
# to a silent 0.
probe_is_valid() {
    local record="$1"

    [[ "$record" == 'unavailable 0 0 -' ]] && return 0
    [[ "$record" =~ ^available\ [0-9]+\ [0-9]+\ [^[:space:]]+$ ]]
}

probe_is_available() {
    local record="$1"

    probe_is_valid "$record" && [[ "$record" == available\ * ]]
}

# probe_compare: the single owner of delta eligibility and signed
# subtraction. Prints one line:
#
#   "available <signed_delta>"    both probes measured the same thing
#   "unavailable <reason>"        they did not, with the reason to report
#
# Eligibility is deliberately total and deliberately strict: both records
# must be valid and available, and their sources must be non-empty and
# identical. A missing, malformed, failed, empty-source or changed-source
# provenance yields "unavailable" for every runtime -- there is no runtime
# for which a cross-source subtraction is a measurement. Docker's two
# sources were measured disagreeing by ~9 GB on one cache (premise (d),
# plans/cache-prune-reclaim-effectiveness.md); subtracting one from the
# other reports that disagreement as if it were freed disk.
#
# Always exits 0: "these cannot be compared" is an answer, not an error.
probe_compare() {
    local name="$1"
    local before="$2"
    local after="$3"
    local before_total before_source after_total after_source

    if ! probe_is_available "$before"; then
        printf 'unavailable the pre-action size probe failed\n'
        return 0
    fi

    if ! probe_is_available "$after"; then
        printf 'unavailable the post-action size probe failed\n'
        return 0
    fi

    read -r _ before_total _ before_source <<< "$before"
    read -r _ after_total _ after_source <<< "$after"

    if [[ -z "$before_source" || -z "$after_source" || "$before_source" != "$after_source" ]]; then
        printf 'unavailable %s size source changed between probes: %s -> %s\n' \
            "$name" "${before_source:-none}" "${after_source:-none}"
        return 0
    fi

    printf 'available %d\n' "$((before_total - after_total))"
}

# human_bytes: render a byte count as a short human-readable size.
human_bytes() {
    local bytes="$1"

    awk -v n="$bytes" 'BEGIN {
        split("B KB MB GB TB PB", units, " ")
        i = 1
        while (n >= 1024 && i < 6) {
            n /= 1024
            i++
        }
        printf "%.1f%s", n, units[i]
    }'
}

# human_bytes_signed: like human_bytes, but tolerates a negative byte count.
# An observed footprint delta can be negative (a concurrent cache write
# growing the cache between the before/after probes), and human_bytes's own
# magnitude comparison (`n >= 1024`) is never true for a negative n, so a
# large negative delta would otherwise render as a bare "-5000000000.0B"
# instead of converting units. Strip the sign, format the magnitude,
# reattach it.
human_bytes_signed() {
    local bytes="$1"
    local sign=""

    if ((bytes < 0)); then
        sign="-"
        bytes=$((-bytes))
    fi

    printf '%s%s' "$sign" "$(human_bytes "$bytes")"
}
