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

# High-signal string IOCs shared across the whole TeamPCP/Miasma/Hades campaign:
# C2 accounts, magic search keywords, payload internals, the Hades PyPI fallback
# discovery strings, the run-once / SSH-propagation markers. Same stealer whether
# it arrived via npm or PyPI. Consumed by the sibling modules the router sources.
# shellcheck disable=SC2034
IOC_RE='Miasma|Shai-Hulud|liuende501|thebeautifulmarchoftime|thebeautifulsnadsoftime|IfYouInvalidateThisTokenItWillNukeTheComputerOfTheOwner|gh-token-monitor|\.bun_ran|\.sshu-setup\.js'

# Code markers inside the obfuscated JS stealer payload (`_index.js` on PyPI,
# root `index.js` on npm) and the weaponized npm binding.gyp -- the Bun-staged
# stealer is identical across both ecosystems.
# shellcheck disable=SC2034
PAYLOAD_MARKERS='globalThis\.getBunPath|createDecipheriv\("aes-128-gcm"|<!\(node index\.js|oven-sh/bun/releases/download/bun-v1\.3\.13'

hr() { printf '%*s\n' 65 '' | tr ' ' '='; }
section() { SECTION=$((SECTION+1)); printf '\n[%d] %s\n' "$SECTION" "$1"; }
# This sourced helper mutates the router-owned verdict state.
# shellcheck disable=SC2034
hit() { FOUND=1; printf '  HIT: %s\n' "$*"; }
review() { REVIEWS=$((REVIEWS+1)); printf '  REVIEW: %s\n' "$*"; }
info() { printf '  %s\n' "$*"; }

# Shared evidence display: FILE's lines matching REGEX, indented, capped at LIMIT
# lines (0 = uncapped). The cap is part of each call site's contract, so it is
# always passed explicitly and the per-site limits stay distinct.
show_matches() { # file regex limit [icase]
  local cap=(cat); [ "$3" -gt 0 ] && cap=(head -n "$3")
  grep "-nE${4:+i}" "$2" "$1" 2>/dev/null | sed 's/^/    /' | "${cap[@]}"
}

# The "grep for markers -> report -> show the matched lines" idiom, with KIND the
# reporter (hit/review). Returns 0 only when it reported, so a call site can fall
# through to its own secondary classification.
report_markers() { # kind message file regex limit [icase]
  grep "-Eq${6:+i}" "$4" "$3" 2>/dev/null || return 1
  "$1" "$2"
  show_matches "$3" "$4" "$5" "${6:-}"
}

# Print, NUL-separated, each existing regular file from the argument list exactly
# once (deduped by resolved path), so a candidate config list cannot double-report
# symlinked duplicates.
dedupe_existing_files() {
  local nl=$'\n' seen=$'\n' f real
  for f in "$@"; do
    [ -f "$f" ] || continue
    real="$(readlink -f "$f" 2>/dev/null || printf '%s' "$f")"
    case "$seen" in *"$nl$real$nl"*) continue ;; esac
    seen="${seen}${real}${nl}"
    printf '%s\0' "$f"
  done
}

common_check_daemon() {
  section "gh-token-monitor dead-man's-switch daemon"
  # Polls GitHub every ~60s; recursively deletes files if it sees its token
  # revoked. Listing only -- do not stop/remove until the machine is isolated.
  # Test the captured OUTPUT and route through hit() (FP rule 4): an earlier draft
  # only set daemon_seen here, so a LIVE unit never changed the exit code.
  local daemon_seen=0 ud u m scope
  if command -v systemctl >/dev/null 2>&1; then
    for scope in "" "--user"; do
      # shellcheck disable=SC2086  # one controlled literal flag, or empty
      m="$(systemctl $scope list-units --all 2>/dev/null | grep -i 'gh-token-monitor')"
      [ -n "$m" ] || continue
      daemon_seen=1
      hit "gh-token-monitor unit listed by systemctl${scope:+ $scope}:"
      printf '%s\n' "$m" | sed 's/^/    /'
    done
  fi
  # File-level sweep is the PRIMARY signal (systemctl/launchctl above could lie on
  # a compromised host): transient (/run), vendor (/usr/lib) and XDG unit dirs too.
  local unit_dirs=(
    "$HOME/.config/systemd/user" "/etc/systemd/system" "/etc/systemd/user"
    "/usr/lib/systemd/system" "/usr/lib/systemd/user" "/run/systemd/system"
    "$HOME/Library/LaunchAgents" "/Library/LaunchAgents" "/Library/LaunchDaemons"
  )
  [ -n "${XDG_CONFIG_HOME:-}" ] && [ "${XDG_CONFIG_HOME%/}" != "$HOME/.config" ] \
    && unit_dirs+=("${XDG_CONFIG_HOME%/}/systemd/user")
  for ud in "${unit_dirs[@]}"; do
    [ -d "$ud" ] || continue
    while IFS= read -r -d '' u; do
      daemon_seen=1
      hit "gh-token-monitor unit/agent: $u"
    done < <(find "$ud" -maxdepth 1 -type f -iname '*gh-token-monitor*' -print0 2>/dev/null)
    while IFS= read -r -d '' u; do
      grep -qi 'gh-token-monitor' "$u" 2>/dev/null || continue
      daemon_seen=1
      hit "gh-token-monitor reference inside: $u"
    done < <(find "$ud" -maxdepth 1 -type f \( -name '*.service' -o -name '*.plist' \) -print0 2>/dev/null)
  done
  if command -v launchctl >/dev/null 2>&1 \
    && { m="$(launchctl list 2>/dev/null | grep -i 'gh-token-monitor')"; [ -n "$m" ]; }; then
    daemon_seen=1
    hit "gh-token-monitor agent listed by launchctl:"
    printf '%s\n' "$m" | sed 's/^/    /'
  fi
  [ "$daemon_seen" -eq 0 ] && info "no gh-token-monitor daemon found"
}

common_check_bun_artifacts() {
  section "Bun runtime artifacts (evasion: payload runs off-Node)"
  local bun_seen=0 b pjs troot m
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
      # portable spelling: on FreeBSD "-e" means "show environment" (rule 8).
      # shellcheck disable=SC2009  # ps|grep is portable; pgrep -f not guaranteed everywhere
      m="$(ps axo args= 2>/dev/null | grep -E "$troot/(\.?b[-_][^ ]*)/bun" | grep -v grep)"
      [ -n "$m" ] || continue
      bun_seen=1
      hit "bun process executing from temp staging dir:"
      printf '%s\n' "$m" | sed 's/^/    /'
    fi
  done
  [ "$bun_seen" -eq 0 ] && info "no suspicious bun artifacts found"
}

common_check_sudoers() {
  section "Passwordless-sudo persistence"
  if [ -d /etc/sudoers.d ]; then
    local sudo_seen=0 sf
    while IFS= read -r sf; do
      sudo_seen=1
      review "NOPASSWD rule present (confirm it is intentional): $sf"
    done < <(grep -RIl 'NOPASSWD' /etc/sudoers.d 2>/dev/null | grep -v -e '/README')
    [ "$sudo_seen" -eq 0 ] && info "sudoers.d check skipped or no NOPASSWD rules readable"
  else
    info "no /etc/sudoers.d directory"
  fi
}

common_check_hosts_file() {
  section "Hosts file DNS redirection"
  # Includes the StepSecurity telemetry domains: the Hades stealer reportedly
  # black-holes them to silence harden-runner, so a redirection there is a tamper
  # signal -- but editing /etc/hosts is legitimate and common, so REVIEW not HIT.
  if [ ! -f "$HOSTS_FILE" ]; then
    info "hosts file not readable: $HOSTS_FILE"
  elif grep -Ei '^[[:space:]]*(127\.0\.0\.1|0\.0\.0\.0)[[:space:]].*(github\.com|api\.github\.com|registry\.npmjs\.org|npmjs\.org|nodejs\.org|pypi\.org|files\.pythonhosted\.org|api\.anthropic\.com|oven-sh|agent\.stepsecurity\.io|api\.stepsecurity\.io|app\.stepsecurity\.io)' "$HOSTS_FILE" 2>/dev/null; then
    review "developer-service hostname redirection in hosts file (verify intentional): $HOSTS_FILE"
  else
    info "no suspicious developer-service hosts redirection found"
  fi
}

common_check_agent_context() {
  section "Agent context files -- zero-width character injection"
  # NOTE: a leading U+FEFF is a normal BOM and U+200D is part of legitimate emoji
  # ZWJ sequences, so match only mid-line and REVIEW rather than HIT. The class
  # also covers U+2060 and the tag block U+E0000-E007F used by ASCII-smuggling
  # prompt injection. Test perl's OUTPUT, not its exit status (rule 4).
  local ctx zw
  while IFS= read -r -d '' ctx; do
    zw="$(perl -CSD -ne 'print "$ARGV:$.: $_" if /\S[\x{200B}\x{200C}\x{200D}\x{2060}\x{FEFF}\x{E0000}-\x{E007F}]|[\x{200B}\x{200C}\x{200D}\x{2060}\x{FEFF}\x{E0000}-\x{E007F}]\S/' "$ctx" 2>/dev/null)"
    if [ -n "$zw" ]; then
      review "zero-width character inside text (often benign emoji/BOM; verify): $ctx"
      printf '%s\n' "$zw" | sed 's/^/    /' | head -n 5
    fi
  done < <(inventory_root | inventory_select any 'CLAUDE.md' 'AGENTS.md' 'settings.json' '.cursorrules')
}

common_check_shell_rc() {
  section "Shell profiles -- unexpected bun/runtime download"
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile"; do
    [ -f "$rc" ] || continue
    report_markers hit "shell RC IOC: $rc" "$rc" 'oven-sh/bun|getBunPath|gh-token-monitor' 0
  done
}

# Host-level, campaign-wide checks, independent of which ecosystem delivered the
# payload. Run ONCE by the router regardless of how many ecosystems were selected.
# The scan root reaches them through the router-built P1 inventory, so the
# argument the router passes is accepted but unused.
run_common_checks() {
  common_check_daemon
  common_check_bun_artifacts
  common_check_sudoers
  common_check_hosts_file
  common_check_agent_context
  common_check_shell_rc
}
