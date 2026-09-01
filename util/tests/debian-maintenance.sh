#!/usr/bin/env bash
# Hermetic regression tests for ../debian-maintenance.sh.
# Test doubles below replace sourced functions and are invoked indirectly.
# shellcheck disable=SC1091,SC2317

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../debian-maintenance.sh
source "$HERE/../debian-maintenance.sh"

# These arrays are populated by the sourced maintenance functions.
declare -a protected_kernel_packages removable_kernel_packages kernel_purge_packages

PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf '  ok   - %s\n' "$1"
}

bad() {
    FAIL=$((FAIL + 1))
    printf '  FAIL - %s\n' "$1"
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"

    if [[ "$actual" == "$expected" ]]; then
        ok "$label"
    else
        bad "$label (expected <$expected>, got <$actual>)"
    fi
}

assert_success() {
    local label="$1"
    shift

    if "$@"; then
        ok "$label"
    else
        bad "$label"
    fi
}

assert_failure() {
    local label="$1"
    shift

    if "$@"; then
        bad "$label"
    else
        ok "$label"
    fi
}

array_contains() {
    local needle="$1"
    shift
    local item

    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

echo "[inventory] installed-status filtering"
dpkg-query() {
    printf '%s\n' \
        $'linux-image-6.1.0-1-amd64\t6.1.1\tii ' \
        $'linux-image-6.1.0-2-amd64\t6.1.2\trc ' \
        $'linux-image-unsigned-6.1.0-3-amd64\t6.1.3\thi ' \
        $'linux-image-amd64\t6.1.3\tii '
}
inventory="$(query_installed_kernel_records)"
assert_eq $'linux-image-6.1.0-1-amd64\t6.1.1\nlinux-image-unsigned-6.1.0-3-amd64\t6.1.3' \
    "$inventory" "only fully installed concrete signed/unsigned images survive"
unset -f dpkg-query

echo "[retention] newest two plus running"
query_installed_kernel_records() {
    printf '%s\n' \
        $'linux-image-6.1.0-1-amd64\t6.1.1' \
        $'linux-image-6.1.0-2-amd64\t6.1.2' \
        $'linux-image-6.1.0-3-amd64\t6.1.3'
}
boot_artifact_exists() {
    [[ "$1" != "missing" ]]
}
load_installed_kernels
assert_success "newest running kernel is recognized" select_protected_kernels "6.1.0-3-amd64"
assert_eq "2" "${#protected_kernel_packages[@]}" "exactly two kernels protected when newest is running"
assert_eq "linux-image-6.1.0-1-amd64" "${removable_kernel_packages[*]}" "oldest kernel is the only removal candidate"

load_installed_kernels
assert_success "older running kernel is recognized" select_protected_kernels "6.1.0-1-amd64"
assert_eq "3" "${#protected_kernel_packages[@]}" "running kernel is retained in addition to newest two"
assert_eq "0" "${#removable_kernel_packages[@]}" "no kernel is removable when all three are protected"

load_installed_kernels
assert_failure "missing running package blocks cleanup" select_protected_kernels "6.1.0-99-amd64"

boot_artifact_exists() {
    [[ "$1" != "6.1.0-2-amd64" ]]
}
load_installed_kernels
assert_failure "missing protected boot artifact blocks cleanup" select_protected_kernels "6.1.0-3-amd64"

echo "[purge list] exact release companions"
boot_artifact_exists() { return 0; }
load_installed_kernels
select_protected_kernels "6.1.0-3-amd64"
package_is_installed() {
    case "$1" in
        linux-image-6.1.0-1-amd64|linux-headers-6.1.0-1-amd64|linux-modules-6.1.0-1-amd64)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
build_kernel_purge_list
assert_success "old image included" array_contains "linux-image-6.1.0-1-amd64" "${kernel_purge_packages[@]}"
assert_success "old modules included" array_contains "linux-modules-6.1.0-1-amd64" "${kernel_purge_packages[@]}"
assert_failure "protected image excluded" array_contains "linux-image-6.1.0-3-amd64" "${kernel_purge_packages[@]}"
assert_failure "shared ABI header is not guessed" array_contains "linux-headers-6.1.0-1" "${kernel_purge_packages[@]}"

echo "[transaction policy] boot-critical removals"
assert_success "kernel image is boot critical" is_boot_critical_package "linux-image-6.1.0-1-amd64"
assert_success "kernel modules are boot critical" is_boot_critical_package "linux-modules-6.1.0-1-amd64"
assert_success "GRUB is boot critical" is_boot_critical_package "grub-efi-amd64"
assert_success "initramfs tools are boot critical" is_boot_critical_package "initramfs-tools-core"
assert_failure "ordinary orphan is not boot critical" is_boot_critical_package "orphaned-library"

APT_SIMULATION=""
APT_LOG=""
CONFIRM_RESULT=0
apt-get() {
    if [[ "${1:-}" == -s ]]; then
        printf '%s\n' "$APT_SIMULATION"
        return 0
    fi
    APT_LOG+="$*|"
}
confirm() {
    return "$CONFIRM_RESULT"
}

APT_SIMULATION=$'Inst package-a\nRemv linux-image-6.1.0-1-amd64'
APT_LOG=""
run_full_upgrade >/dev/null 2>&1
assert_eq "" "$APT_LOG" "full-upgrade is blocked for kernel removal"

APT_SIMULATION=$'Inst package-a\nRemv obsolete-library'
APT_LOG=""
CONFIRM_RESULT=0
run_full_upgrade >/dev/null 2>&1
assert_eq "-y full-upgrade|" "$APT_LOG" "approved benign full-upgrade runs once"

APT_LOG=""
CONFIRM_RESULT=1
run_full_upgrade >/dev/null 2>&1
assert_eq "" "$APT_LOG" "declined full-upgrade does not execute"

APT_SIMULATION=$'Remv linux-modules-6.1.0-1-amd64'
APT_LOG=""
CONFIRM_RESULT=0
run_autoremove >/dev/null 2>&1
assert_eq "" "$APT_LOG" "autoremove is blocked for kernel modules"

APT_SIMULATION=$'Remv orphaned-library'
APT_LOG=""
run_autoremove >/dev/null 2>&1
assert_eq "-y autoremove --purge|" "$APT_LOG" "approved benign autoremove runs once"

echo "[archive cleanup] Del-format parser (the autoclean trap)"
assert_success "Del-format preview is recognised as archive work" \
    archive_transaction_has_changes $'Del chatgpt 26.818.61809 [389 MB]'
assert_failure "Inst/Remv-only preview is not treated as archive work" \
    archive_transaction_has_changes $'Inst package-a\nRemv obsolete-library'

echo "[archive cleanup] run_apt_cache_cleanup stages"
du() { printf '1.0K\t%s\n' "$1"; }

# confirm() is queue-driven here so the two independent confirms (autoclean,
# then clean) can be scripted separately per test case.
declare -a CONFIRM_QUEUE=()
confirm() {
    local result="${CONFIRM_QUEUE[0]:-1}"
    CONFIRM_QUEUE=("${CONFIRM_QUEUE[@]:1}")
    return "$result"
}

APT_SIMULATION=""
APT_LOG=""
CONFIRM_QUEUE=(1)
run_apt_cache_cleanup >/dev/null 2>&1
assert_eq "" "$APT_LOG" "empty/no-op preview plus declined clean: nothing executes"

APT_SIMULATION=$'Del chatgpt 26.818.61809 [389 MB]'
APT_LOG=""
CONFIRM_QUEUE=(0 1)
run_apt_cache_cleanup >/dev/null 2>&1
assert_eq "-y autoclean|" "$APT_LOG" "confirmed autoclean runs apt-get -y autoclean exactly once"

APT_SIMULATION=$'Del chatgpt 26.818.61809 [389 MB]'
APT_LOG=""
CONFIRM_QUEUE=(1 1)
run_apt_cache_cleanup >/dev/null 2>&1
assert_eq "" "$APT_LOG" "declined autoclean executes nothing"

APT_SIMULATION=$'Del chatgpt 26.818.61809 [389 MB]'
APT_LOG=""
CONFIRM_QUEUE=(0 1)
run_apt_cache_cleanup >/dev/null 2>&1
case "$APT_LOG" in
    *autoclean*clean*) bad "clean must not run before its own separate confirm (log: $APT_LOG)" ;;
    *autoclean*) ok "clean runs only after its own separate confirm" ;;
    *) bad "expected autoclean in log, got: $APT_LOG" ;;
esac

APT_SIMULATION=$'Del chatgpt 26.818.61809 [389 MB]'
APT_LOG=""
CONFIRM_QUEUE=(0 0)
run_apt_cache_cleanup >/dev/null 2>&1
assert_eq "-y autoclean|-y clean|" "$APT_LOG" "confirming both runs autoclean then clean, in that order"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
