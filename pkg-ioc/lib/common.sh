# shellcheck shell=bash
# ============================================================================
# pkg-ioc :: lib/common.sh
#
# Shared, ecosystem-agnostic machinery for the router (scan.sh) and the
# per-ecosystem sub-scanners (npm.sh, pypi.sh). Sourced -- defines constants
# and functions only, runs nothing at load time. The router owns `set -uo
# pipefail` and the FOUND/REVIEWS/SECTION globals; the helpers below mutate
# them, so this file must be sourced (not exec'd) into the router's process.
#
# Detection-only and read-only. See AGENTS.md for the design contract.
# ============================================================================

# High-signal string IOCs shared across the whole TeamPCP/Miasma/Hades campaign
# (C2 accounts, magic search keywords, payload internals, the Hades PyPI fallback
# discovery strings, and the run-once / SSH-propagation markers). Same stealer,
# regardless of whether it was delivered via npm or PyPI.
IOC_RE='Miasma|Shai-Hulud|liuende501|thebeautifulmarchoftime|thebeautifulsnadsoftime|IfYouInvalidateThisTokenItWillNukeTheComputerOfTheOwner|gh-token-monitor|\.bun_ran|\.sshu-setup\.js'

# Code markers found inside the obfuscated JS stealer payload (`_index.js` on
# PyPI, root `index.js` on npm) and the weaponized npm binding.gyp. The Bun-
# staged stealer is identical across both ecosystems.
PAYLOAD_MARKERS='globalThis\.getBunPath|createDecipheriv\("aes-128-gcm"|<!\(node index\.js|oven-sh/bun/releases/download/bun-v1\.3\.13'

hr() { printf '%*s\n' 65 '' | tr ' ' '='; }
section() { SECTION=$((SECTION+1)); printf '\n[%d] %s\n' "$SECTION" "$1"; }
hit() { FOUND=1; printf '  HIT: %s\n' "$*"; }
review() { REVIEWS=$((REVIEWS+1)); printf '  REVIEW: %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }

# Print, NUL-separated, each existing regular file from the argument list exactly
# once (deduped by resolved path) -- used to scan a candidate config list without
# double-reporting symlinked duplicates.
dedupe_existing_files() {
  local seen="" f real
  for f in "$@"; do
    [ -f "$f" ] || continue
    real="$(readlink -f "$f" 2>/dev/null || printf '%s' "$f")"
    case "
$seen
" in
      *"
$real
"*) continue ;;
    esac
    seen="${seen}${real}
"
    printf '%s\0' "$f"
  done
}

# Host-level, campaign-wide checks that are independent of which package
# ecosystem delivered the payload. Run ONCE by the router regardless of how many
# ecosystems were selected.
run_common_checks() {
  local ROOT="$1"

  section "gh-token-monitor dead-man's-switch daemon"
  # Polls GitHub every ~60s; recursively deletes files if it sees its token
  # revoked. Listing only -- do not stop/remove until the machine is isolated.
  # Test the captured OUTPUT and route through hit() (FP rule 4 discipline): an
  # earlier draft set only daemon_seen on the systemctl match, so a LIVE unit
  # printed raw grep output and never changed the exit code.
  local daemon_seen=0 ud u m
  if command -v systemctl >/dev/null 2>&1; then
    m="$(systemctl list-units --all 2>/dev/null | grep -i 'gh-token-monitor')"
    if [ -n "$m" ]; then
      daemon_seen=1
      hit "gh-token-monitor unit listed by systemctl:"
      printf '%s\n' "$m" | sed 's/^/    /'
    fi
    m="$(systemctl --user list-units --all 2>/dev/null | grep -i 'gh-token-monitor')"
    if [ -n "$m" ]; then
      daemon_seen=1
      hit "gh-token-monitor unit listed by systemctl --user:"
      printf '%s\n' "$m" | sed 's/^/    /'
    fi
  fi
  # File-level sweep is the PRIMARY signal (systemctl/launchctl above could lie
  # on a compromised host): include transient (/run) and vendor (/usr/lib) unit
  # dirs, and an XDG override location when it differs from ~/.config.
  local unit_dirs=(
    "$HOME/.config/systemd/user" "/etc/systemd/system" "/etc/systemd/user"
    "/usr/lib/systemd/system" "/usr/lib/systemd/user" "/run/systemd/system"
    "$HOME/Library/LaunchAgents" "/Library/LaunchAgents" "/Library/LaunchDaemons"
  )
  if [ -n "${XDG_CONFIG_HOME:-}" ] && [ "${XDG_CONFIG_HOME%/}" != "$HOME/.config" ]; then
    unit_dirs+=("${XDG_CONFIG_HOME%/}/systemd/user")
  fi
  for ud in "${unit_dirs[@]}"; do
    [ -d "$ud" ] || continue
    while IFS= read -r -d '' u; do
      daemon_seen=1
      hit "gh-token-monitor unit/agent: $u"
    done < <(find "$ud" -maxdepth 1 -type f -iname '*gh-token-monitor*' -print0 2>/dev/null)
    while IFS= read -r -d '' u; do
      if grep -qi 'gh-token-monitor' "$u" 2>/dev/null; then
        daemon_seen=1
        hit "gh-token-monitor reference inside: $u"
      fi
    done < <(find "$ud" -maxdepth 1 -type f \( -name '*.service' -o -name '*.plist' \) -print0 2>/dev/null)
  done
  if command -v launchctl >/dev/null 2>&1; then
    m="$(launchctl list 2>/dev/null | grep -i 'gh-token-monitor')"
    if [ -n "$m" ]; then
      daemon_seen=1
      hit "gh-token-monitor agent listed by launchctl:"
      printf '%s\n' "$m" | sed 's/^/    /'
    fi
  fi
  [ "$daemon_seen" -eq 0 ] && info "no gh-token-monitor daemon found"

  section "Bun runtime artifacts (evasion: payload runs off-Node)"
  local bun_seen=0 b pjs troot
  for troot in "${TMP_ROOTS[@]}"; do
    [ -d "$troot" ] || continue
    while IFS= read -r -d '' b; do
      bun_seen=1
      hit "bun binary in temp dir (worm staging): $b"
    done < <(find "$troot" -maxdepth 2 -type f -name 'bun' \( -path '*/b-*' -o -path '*/.b_*' \) -print0 2>/dev/null)
    while IFS= read -r -d '' pjs; do
      bun_seen=1
      hit "temp JavaScript payload artifact: $pjs"
    done < <(find "$troot" -maxdepth 1 -type f -name 'p*.js' -print0 2>/dev/null)
    if command -v ps >/dev/null 2>&1; then
      # Only flag bun executing from the worm's mktemp staging dir (/tmp/b-XXXX/bun);
      # a bare "bun run" would match legitimate Bun usage. "ps axo args=" is the
      # portable spelling: on FreeBSD "-e" means "show environment", not "every
      # process", so "-eo args" silently scans the wrong thing there.
      # shellcheck disable=SC2009  # ps|grep is portable; pgrep -f not guaranteed everywhere
      m="$(ps axo args= 2>/dev/null | grep -E "$troot/(\.?b[-_][^ ]*)/bun" | grep -v grep)"
      if [ -n "$m" ]; then
        bun_seen=1
        hit "bun process executing from temp staging dir:"
        printf '%s\n' "$m" | sed 's/^/    /'
      fi
    fi
  done
  [ "$bun_seen" -eq 0 ] && info "no suspicious bun artifacts found"

  section "Passwordless-sudo persistence"
  if [ -d /etc/sudoers.d ]; then
    local sudo_seen=0 sf
    while IFS= read -r sf; do
      sudo_seen=1
      review "NOPASSWD rule present (confirm it is intentional): $sf"
    done < <(grep -RIl 'NOPASSWD' /etc/sudoers.d 2>/dev/null | grep -v -e '/README')
    if [ "$sudo_seen" -eq 0 ]; then
      info "sudoers.d check skipped or no NOPASSWD rules readable"
    fi
  else
    info "no /etc/sudoers.d directory"
  fi

  section "Hosts file DNS redirection"
  # Adds the StepSecurity telemetry domains: the Hades stealer reportedly blocks
  # them (redirects to a black-hole IP) to silence harden-runner defensive
  # tooling, so a redirection of those is a tamper signal -- but legitimately
  # editing /etc/hosts is common, so REVIEW (not HIT).
  if [ -f "$HOSTS_FILE" ]; then
    if grep -Ei '^[[:space:]]*(127\.0\.0\.1|0\.0\.0\.0)[[:space:]].*(github\.com|api\.github\.com|registry\.npmjs\.org|npmjs\.org|nodejs\.org|pypi\.org|files\.pythonhosted\.org|api\.anthropic\.com|oven-sh|agent\.stepsecurity\.io|api\.stepsecurity\.io|app\.stepsecurity\.io)' "$HOSTS_FILE" 2>/dev/null; then
      review "developer-service hostname redirection in hosts file (verify intentional): $HOSTS_FILE"
    else
      info "no suspicious developer-service hosts redirection found"
    fi
  else
    info "hosts file not readable: $HOSTS_FILE"
  fi

  section "Agent context files -- zero-width character injection"
  # NOTE: U+FEFF as the very first byte is a normal UTF-8 BOM and U+200D is part
  # of legitimate emoji ZWJ sequences, so match these only mid-line and report
  # them for review rather than as a hard hit. The class also covers U+2060
  # (word joiner) and the Unicode tag block U+E0000-E007F used by ASCII-smuggling
  # prompt injection. Test perl's OUTPUT, not its exit status -- perl -ne always
  # exits 0 whether or not the pattern matched.
  local ctx zw
  while IFS= read -r -d '' ctx; do
    zw="$(perl -CSD -ne 'print "$ARGV:$.: $_" if /\S[\x{200B}\x{200C}\x{200D}\x{2060}\x{FEFF}\x{E0000}-\x{E007F}]|[\x{200B}\x{200C}\x{200D}\x{2060}\x{FEFF}\x{E0000}-\x{E007F}]\S/' "$ctx" 2>/dev/null)"
    if [ -n "$zw" ]; then
      review "zero-width character inside text (often benign emoji/BOM; verify): $ctx"
      printf '%s\n' "$zw" | sed 's/^/    /' | head -n 5
    fi
  done < <(find "$ROOT" \
    \( -path '*/node_modules' -o -path '*/.git' \) -prune -o \
    \( -name CLAUDE.md -o -name AGENTS.md -o -name settings.json -o -name .cursorrules \) \
    -print0 2>/dev/null)

  section "Shell profiles -- unexpected bun/runtime download"
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile"; do
    if [ -f "$rc" ] && grep -Eq 'oven-sh/bun|getBunPath|gh-token-monitor' "$rc" 2>/dev/null; then
      hit "shell RC IOC: $rc"
      grep -nE 'oven-sh/bun|getBunPath|gh-token-monitor' "$rc" 2>/dev/null | sed 's/^/    /'
    fi
  done
}
