#!/usr/bin/env bash
set -euo pipefail

# debian-maintenance.sh
# Conservative APT maintenance helper for Debian-based systems.

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root, e.g.: sudo $0"
    exit 1
fi

export DEBIAN_FRONTEND=readline

confirm() {
    local prompt="${1:-Continue?}"
    local reply
    read -r -p "$prompt [y/N] " reply
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

section() {
    printf '\n==== %s ====\n' "$1"
}

section "APT update"
apt update

section "Upgradeable packages"

upgrade_sim="$(apt-get -s upgrade)"

if echo "$upgrade_sim" | grep -q '^Inst '; then
    echo "$upgrade_sim" | awk '/^Inst / {print "  " $2 " " $3 " -> " $4}'

    if confirm "Apply package upgrades?"; then
        apt-get upgrade
    else
        echo "Skipping package upgrades."
    fi
else
    echo "No upgradeable packages."
fi

section "Autoremove candidates"
# Dry-run autoremove so the package list is visible before approval.
autoremove_output="$(apt-get -s autoremove 2>/dev/null || true)"
echo "$autoremove_output"

if echo "$autoremove_output" | grep -q '^Remv '; then
    if confirm "Run apt-get autoremove?"; then
        apt-get autoremove
    else
        echo "Skipping autoremove."
    fi
else
    echo "No autoremove candidates detected."
fi

section "Installed kernel packages"

running_kernel="$(uname -r)"
echo "Running kernel: $running_kernel"

echo
echo "Installed kernel image packages:"
dpkg-query -W -f='${Package}\t${Version}\n' 'linux-image-*' 2>/dev/null \
    | awk '$1 !~ /linux-image-amd64|linux-image-generic|linux-image-virtual|linux-image-cloud/ {print}' \
    | sort -V || true

echo
echo "Installed kernel header packages:"
dpkg-query -W -f='${Package}\t${Version}\n' 'linux-headers-*' 2>/dev/null \
    | sort -V || true

# Find installed concrete kernel image package names.
mapfile -t kernel_images < <(
    dpkg-query -W -f='${Package}\n' 'linux-image-*' 2>/dev/null \
        | grep -E '^linux-image-[0-9]' \
        | sort -V
)

if ((${#kernel_images[@]} <= 2)); then
    echo
    echo "Two or fewer concrete kernel image packages installed. No kernel cleanup suggested."
    exit 0
fi

# Protect the running kernel package and the newest installed kernel package.
newest_kernel_image="${kernel_images[-1]}"
protected=("$newest_kernel_image")

running_kernel_image=""
for pkg in "${kernel_images[@]}"; do
    if [[ "$pkg" == "linux-image-$running_kernel" ]]; then
        running_kernel_image="$pkg"
        protected+=("$pkg")
    fi
done

echo
echo "Protected kernel image packages:"
printf '  %s\n' "${protected[@]}" | sort -u

echo
echo "Kernel image packages eligible for review/removal:"
remove_images=()
for pkg in "${kernel_images[@]}"; do
    keep=false
    for p in "${protected[@]}"; do
        if [[ "$pkg" == "$p" ]]; then
            keep=true
            break
        fi
    done

    if [[ "$keep" == false ]]; then
        remove_images+=("$pkg")
        echo "  $pkg"
    fi
done

if ((${#remove_images[@]} == 0)); then
    echo "No old kernel image packages eligible for removal."
    exit 0
fi

# Build associated header/module package candidates for the same kernel versions.
remove_pkgs=()
for img in "${remove_images[@]}"; do
    ver="${img#linux-image-}"

    for candidate in \
        "linux-image-$ver" \
        "linux-headers-$ver" \
        "linux-modules-$ver" \
        "linux-modules-extra-$ver"
    do
        if dpkg-query -W -f='${Status}' "$candidate" 2>/dev/null | grep -q 'install ok installed'; then
            remove_pkgs+=("$candidate")
        fi
    done
done

# De-duplicate.
mapfile -t remove_pkgs < <(printf '%s\n' "${remove_pkgs[@]}" | sort -u)

echo
echo "Kernel-related packages proposed for purge:"
printf '  %s\n' "${remove_pkgs[@]}"

echo
echo "This will NOT remove:"
echo "  - the running kernel: $running_kernel"
echo "  - the newest installed kernel image: $newest_kernel_image"

if confirm "Purge the listed old kernel packages?"; then
    apt-get purge "${remove_pkgs[@]}"
    apt-get autoremove
else
    echo "Skipping kernel cleanup."
fi

section "Done"
