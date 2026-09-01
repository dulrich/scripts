#!/usr/bin/env bash
set -euo pipefail

# Conservative, interactive APT maintenance for Debian-based systems.
# Kernel and bootloader package hooks own initramfs/GRUB regeneration; this
# script deliberately does not retry or repair those hooks.

export DEBIAN_FRONTEND=readline

KEEP_NEWEST_KERNELS=2

section() {
    printf '\n==== %s ====\n' "$1"
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

confirm() {
    local prompt="${1:-Continue?}"
    local reply

    read -r -p "$prompt [y/N] " reply
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

require_root() {
    if ((EUID != 0)); then
        die "Run as root, e.g.: sudo $0"
    fi
}

require_tty() {
    if [[ ! -t 0 || ! -t 1 ]]; then
        die "An interactive terminal is required."
    fi
}

transaction_has_changes() {
    grep -Eq '^(Inst|Remv) ' <<< "$1"
}

extract_removals() {
    awk '/^Remv / {print $2}' <<< "$1"
}

is_boot_critical_package() {
    case "$1" in
        linux-base|linux-firmware|linux-image-*|linux-modules-*|grub-*|grub2-*|shim|shim-*|initramfs-tools*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_no_boot_removals() {
    local package
    local blocked=false

    for package in "$@"; do
        if is_boot_critical_package "$package"; then
            printf '  BLOCKED boot-critical removal: %s\n' "$package" >&2
            blocked=true
        fi
    done

    [[ "$blocked" == false ]]
}

run_upgrade() {
    local simulation

    section "Upgradeable packages (new dependencies allowed)"
    simulation="$(apt-get -s upgrade --with-new-pkgs)"
    printf '%s\n' "$simulation"

    if ! transaction_has_changes "$simulation"; then
        echo "No upgradeable packages."
        return 0
    fi

    if confirm "Apply package upgrades?"; then
        apt-get -y upgrade --with-new-pkgs
    else
        echo "Skipping package upgrades."
    fi
}

run_full_upgrade() {
    local simulation
    local -a removals=()

    section "Full-upgrade review"
    simulation="$(apt-get -s full-upgrade)"
    printf '%s\n' "$simulation"

    if ! transaction_has_changes "$simulation"; then
        echo "No remaining full-upgrade transaction."
        return 0
    fi

    mapfile -t removals < <(extract_removals "$simulation")
    if ((${#removals[@]} > 0)) && ! validate_no_boot_removals "${removals[@]}"; then
        echo "Skipping full-upgrade: boot-critical package removal requires manual review."
        return 0
    fi

    if confirm "Apply the reviewed full-upgrade transaction?"; then
        apt-get -y full-upgrade
    else
        echo "Skipping full-upgrade."
    fi
}

query_installed_kernel_records() {
    dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' 'linux-image-*' 2>/dev/null \
        | awk -F '\t' '
            substr($3, 2, 1) == "i" &&
            ($1 ~ /^linux-image-[0-9]/ || $1 ~ /^linux-image-unsigned-[0-9]/) {
                print $1 "\t" $2
            }
        ' || true
}

kernel_release_for_package() {
    case "$1" in
        linux-image-unsigned-*) printf '%s\n' "${1#linux-image-unsigned-}" ;;
        linux-image-*) printf '%s\n' "${1#linux-image-}" ;;
        *) return 1 ;;
    esac
}

declare -a kernel_packages=()
declare -a kernel_versions=()
declare -a kernel_releases=()
declare -a protected_kernel_packages=()
declare -a removable_kernel_packages=()
declare -A protected_kernel_map=()

load_installed_kernels() {
    local package version release
    local i j
    local swap

    kernel_packages=()
    kernel_versions=()
    kernel_releases=()

    while IFS=$'\t' read -r package version; do
        [[ -n "$package" ]] || continue
        release="$(kernel_release_for_package "$package")"
        kernel_packages+=("$package")
        kernel_versions+=("$version")
        kernel_releases+=("$release")
    done < <(query_installed_kernel_records)

    # Sort oldest to newest using Debian's version comparison rules.
    for ((i = 0; i < ${#kernel_packages[@]}; i++)); do
        for ((j = i + 1; j < ${#kernel_packages[@]}; j++)); do
            if dpkg --compare-versions "${kernel_versions[i]}" gt "${kernel_versions[j]}"; then
                swap="${kernel_packages[i]}"
                kernel_packages[i]="${kernel_packages[j]}"
                kernel_packages[j]="$swap"

                swap="${kernel_versions[i]}"
                kernel_versions[i]="${kernel_versions[j]}"
                kernel_versions[j]="$swap"

                swap="${kernel_releases[i]}"
                kernel_releases[i]="${kernel_releases[j]}"
                kernel_releases[j]="$swap"
            fi
        done
    done
}

boot_artifact_exists() {
    [[ -r "/boot/vmlinuz-$1" ]]
}

select_protected_kernels() {
    local running_kernel="$1"
    local count="${#kernel_packages[@]}"
    local start
    local i
    local running_found=false
    local package release

    protected_kernel_packages=()
    removable_kernel_packages=()
    protected_kernel_map=()

    start=$((count - KEEP_NEWEST_KERNELS))
    ((start < 0)) && start=0

    for ((i = start; i < count; i++)); do
        protected_kernel_map["${kernel_packages[$i]}"]=1
    done

    for ((i = 0; i < count; i++)); do
        if [[ "${kernel_releases[$i]}" == "$running_kernel" ]]; then
            protected_kernel_map["${kernel_packages[$i]}"]=1
            running_found=true
        fi
    done

    if [[ "$running_found" == false ]]; then
        die "Running kernel $running_kernel is not represented by a fully installed image package."
        return 1
    fi

    for ((i = 0; i < count; i++)); do
        package="${kernel_packages[$i]}"
        release="${kernel_releases[$i]}"
        if [[ -n "${protected_kernel_map[$package]:-}" ]]; then
            if ! boot_artifact_exists "$release"; then
                die "Protected kernel $package has no readable /boot/vmlinuz-$release."
                return 1
            fi
            protected_kernel_packages+=("$package")
        else
            removable_kernel_packages+=("$package")
        fi
    done
}

package_is_installed() {
    local status

    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null)" || return 1
    [[ "${status:1:1}" == i ]]
}

build_kernel_purge_list() {
    local image release candidate
    local -a candidates=()
    local -A seen=()

    kernel_purge_packages=()
    for image in "${removable_kernel_packages[@]}"; do
        release="$(kernel_release_for_package "$image")"
        candidates=(
            "$image"
            "linux-image-extra-$release"
            "linux-headers-$release"
            "linux-modules-$release"
            "linux-modules-extra-$release"
        )

        for candidate in "${candidates[@]}"; do
            if [[ -z "${seen[$candidate]:-}" ]] && package_is_installed "$candidate"; then
                kernel_purge_packages+=("$candidate")
                seen["$candidate"]=1
            fi
        done
    done
}

declare -a kernel_purge_packages=()

run_kernel_cleanup() {
    local running_kernel

    section "Installed kernel packages"
    running_kernel="$(uname -r)"
    echo "Running kernel: $running_kernel"

    load_installed_kernels
    if ((${#kernel_packages[@]} == 0)); then
        die "No fully installed concrete kernel image packages were found."
        return 1
    fi

    select_protected_kernels "$running_kernel"

    echo
    echo "Protected kernel image packages:"
    printf '  %s\n' "${protected_kernel_packages[@]}"

    if ((${#removable_kernel_packages[@]} == 0)); then
        echo "No old kernel image packages are eligible for removal."
        return 0
    fi

    build_kernel_purge_list
    if ((${#kernel_purge_packages[@]} == 0)); then
        echo "No installed kernel-related packages are eligible for purge."
        return 0
    fi

    echo
    echo "Kernel-related packages proposed for purge:"
    printf '  %s\n' "${kernel_purge_packages[@]}"

    if confirm "Purge the listed old kernel packages?"; then
        apt-get -y purge "${kernel_purge_packages[@]}"
    else
        echo "Skipping kernel cleanup."
    fi
}

run_autoremove() {
    local simulation
    local -a removals=()

    section "Autoremove review"
    simulation="$(apt-get -s autoremove --purge)"
    printf '%s\n' "$simulation"

    mapfile -t removals < <(extract_removals "$simulation")
    if ((${#removals[@]} == 0)); then
        echo "No autoremove candidates detected."
        return 0
    fi

    if ! validate_no_boot_removals "${removals[@]}"; then
        echo "Skipping autoremove: boot-critical package removal requires manual review."
        return 0
    fi

    if confirm "Run the reviewed autoremove transaction?"; then
        apt-get -y autoremove --purge
    else
        echo "Skipping autoremove."
    fi
}

# apt-get -s autoclean emits `Del ` lines, not the `Inst`/`Remv` lines that
# transaction_has_changes/extract_removals match — deliberately a separate
# helper rather than reusing those, which would silently see "no changes"
# forever.
archive_transaction_has_changes() {
    grep -Eq '^Del ' <<< "$1"
}

run_apt_cache_cleanup() {
    local archive_dir="/var/cache/apt/archives"
    local usage
    local simulation

    section "APT archive cleanup"

    if usage="$(du -sh "$archive_dir" 2>&1)"; then
        printf '%s\n' "$usage"
    else
        echo "Unable to read archive footprint for $archive_dir; skipping cache cleanup."
        return 0
    fi

    simulation="$(apt-get -s autoclean)"
    printf '%s\n' "$simulation"

    if ! archive_transaction_has_changes "$simulation"; then
        echo "No cached .debs eligible for autoclean."
    elif confirm "Remove cached .debs that can no longer be downloaded?"; then
        apt-get -y autoclean
    else
        echo "Skipping autoclean."
    fi

    # Independent of stage one: a "no" here is normal and leaves stage one's
    # result intact.
    if confirm "Also clear ALL cached .debs (forces re-download on next install)?"; then
        apt-get -y clean
    else
        echo "Skipping full cache clear."
    fi
}

main() {
    if (($# != 0)); then
        die "usage: $0"
        return 2
    fi

    require_root
    require_tty

    section "APT update"
    apt-get update

    run_upgrade
    apt-get check
    run_full_upgrade
    apt-get check
    run_kernel_cleanup
    run_autoremove
    run_apt_cache_cleanup

    section "Done"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
