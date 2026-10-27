#!/usr/bin/env bash
# Fast, offline test suite for zenreset.sh.
# Run: ./test/run-tests.sh   (or: make test)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/zenreset.sh"

pass=0
fail=0
failed_names=()

check() { # name function
  local name="$1"; shift
  if "$@" >/tmp/zenreset-test.out 2>&1; then
    printf '  ok   %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  FAIL %s\n' "$name"
    sed 's/^/       /' /tmp/zenreset-test.out
    failed_names+=("$name")
    fail=$((fail + 1))
  fi
}

# --- seams -------------------------------------------------------------------

# Read-only commands must not create state in $HOME.
t_readonly_no_side_effects() {
  local tmp n
  tmp=$(mktemp -d)
  ( unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
    HOME="$tmp" "$SCRIPT" version >/dev/null 2>&1 ) || { rm -rf "$tmp"; return 1; }
  n=$(find "$tmp" -mindepth 1 | wc -l)
  rm -rf "$tmp"
  [ "$n" -eq 0 ]
}

# doctor must not leave an engine or privoxy running when a boot test fails.
t_doctor_cleans_up_failed_engine() {
  local tmp cfg live=0 f p
  command -v privoxy >/dev/null 2>&1 || [ -x /usr/sbin/privoxy ] || {
    echo "skip: privoxy not installed"; return 0; }
  tmp=$(mktemp -d)
  cfg="$tmp/.config/zenreset"
  mkdir -p "$cfg" "$tmp/.local/share/zenreset/bin"
  cat > "$cfg/config.env" <<EOF
ENGINES="usque"
ENGINE_BOOT_WAIT=0
PROXY_WAIT=1
SOCKS_PORT=19086
HTTP_PORT=19118
EOF
  cat > "$tmp/.local/share/zenreset/bin/usque" <<'FAKE'
#!/bin/sh
case "$1" in register) exit 0 ;; esac
exec sleep 300
FAKE
  chmod +x "$tmp/.local/share/zenreset/bin/usque"

  ( unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
    HOME="$tmp" "$SCRIPT" doctor --no-fetch ) >/dev/null 2>&1
  sleep 0.5

  for f in "$tmp"/.local/share/zenreset/run/*.pid; do
    [ -f "$f" ] || continue
    p=$(cat "$f" 2>/dev/null) || continue
    if kill -0 "$p" 2>/dev/null; then
      echo "leftover $(basename "$f" .pid) still running (pid $p)"
      live=1
      kill "$p" 2>/dev/null
    fi
    rm -f "$f"
  done
  if pgrep -f "privoxy.*$tmp" >/dev/null 2>&1; then
    echo "leftover privoxy process for $tmp"
    live=1
    pkill -f "privoxy.*$tmp" 2>/dev/null
  fi
  rm -rf "$tmp"
  [ "$live" -eq 0 ]
}

# NO_COLOR (and a non-tty) must produce clean, pasteable output.
t_nocolor_output() {
  local tmp out
  tmp=$(mktemp -d)
  out=$( ( unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
           HOME="$tmp" NO_COLOR=1 "$SCRIPT" status 2>&1 ) )
  rm -rf "$tmp"
  if printf '%s' "$out" | grep -q $'\033'; then
    echo "ANSI escapes present with NO_COLOR=1:"
    printf '%s\n' "$out" | cat -v | sed 's/^/       /'
    return 1
  fi
  return 0
}

# uninstall must refuse to delete state without confirmation, and --yes must work.
t_uninstall_requires_confirmation() {
  local tmp cfg rc survived removed
  tmp=$(mktemp -d)
  cfg="$tmp/.config/zenreset"
  mkdir -p "$cfg"
  echo '# marker' > "$cfg/config.env"

  ( unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
    HOME="$tmp" "$SCRIPT" uninstall </dev/null ) >/dev/null 2>&1
  rc=$?
  survived=0; [ -f "$cfg/config.env" ] && survived=1

  ( unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
    HOME="$tmp" "$SCRIPT" uninstall --yes </dev/null ) >/dev/null 2>&1
  removed=0; [ ! -e "$cfg" ] && removed=1

  rm -rf "$tmp"
  [ "$rc" -ne 0 ] && [ "$survived" -eq 1 ] && [ "$removed" -eq 1 ]
}

# doctor must not waste time boot-testing engines that cannot work under proot.
t_doctor_skips_warp_plus_under_proot() {
  local tmp cfg out n
  tmp=$(mktemp -d)
  cfg="$tmp/.config/zenreset"
  mkdir -p "$cfg" "$tmp/.local/share/zenreset/bin"
  cat > "$cfg/config.env" <<EOF
ENGINES="warp-plus-linux warp-plus-android"
ENGINE_BOOT_WAIT=0
PROXY_WAIT=1
SOCKS_PORT=19086
HTTP_PORT=19118
EOF
  for e in warp-plus-linux warp-plus-android; do
    cat > "$tmp/.local/share/zenreset/bin/$e" <<EOF
#!/bin/sh
echo ran >> "$tmp/ran"
exec sleep 300
EOF
    chmod +x "$tmp/.local/share/zenreset/bin/$e"
  done

  out=$( unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
         PROOT_L2S_DIR=/fake/proot HOME="$tmp" "$SCRIPT" doctor --no-fetch 2>&1 )
  n=$(printf '%s\n' "$out" | grep -c 'skipping boot test under proot')
  if [ -e "$tmp/ran" ]; then
    echo "doctor executed a warp-plus binary under proot"
    rm -rf "$tmp"; return 1
  fi
  if [ "$n" -ne 2 ]; then
    echo "expected 2 skip messages, got $n; output:"
    printf '%s\n' "$out" | sed 's/^/  /'
    rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
  return 0
}

echo
echo "zenreset tests"
check "version/help leave \$HOME untouched" t_readonly_no_side_effects
check "doctor stops a failed engine and its bridge" t_doctor_cleans_up_failed_engine
check "doctor skips warp-plus boot tests under proot" t_doctor_skips_warp_plus_under_proot
check "uninstall refuses without confirmation" t_uninstall_requires_confirmation
check "NO_COLOR output has no ANSI escapes" t_nocolor_output
echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
