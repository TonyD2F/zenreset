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

# Shared fixture: a fake opencode that records its argv, and a "running" engine
# so `serve` does not try to start one.
_serve_fixture() {
  local tmp="$1" cfg="$1/.config/zenreset"
  mkdir -p "$cfg" "$tmp/.local/share/zenreset/run" "$tmp/.local/share/zenreset/log" "$tmp/bin"
  cat > "$cfg/config.env" <<EOF
ENGINES="usque"
SERVE_WAIT=0
SOCKS_PORT=19086
HTTP_PORT=19118
EOF
  {
    echo '#!/bin/sh'
    echo "echo \"\$@\" >> \"$tmp/args\""
    echo 'exec sleep 300'
  } > "$tmp/bin/opencode"
  chmod +x "$tmp/bin/opencode"
  sleep 300 &
  echo $! > "$tmp/.local/share/zenreset/run/engine.pid"
}

_serve_cleanup() {
  local tmp="$1" f p
  for f in "$tmp"/.local/share/zenreset/run/*.pid; do
    [ -f "$f" ] || continue
    p=$(cat "$f" 2>/dev/null) || continue
    kill "$p" 2>/dev/null
    rm -f "$f"
  done
  rm -rf "$tmp"
}

# Pressing Enter at both prompts must serve on the configured defaults.
t_serve_prompt_defaults_on_enter() {
  local tmp out got
  command -v script >/dev/null 2>&1 || { echo "skip: script not available"; return 0; }
  tmp=$(mktemp -d)
  _serve_fixture "$tmp"
  out=$(printf '\n\n' | script -qec "env HOME='$tmp' PATH='$tmp/bin:$PATH' '$SCRIPT' serve --bg" /dev/null 2>&1)
  got=$(cat "$tmp/args" 2>/dev/null)
  _serve_cleanup "$tmp"
  case "$out" in *"Serve on IP"*) ;; *) echo "no IP prompt shown: $out"; return 1 ;; esac
  case "$got" in
    *"--hostname 127.0.0.1"*"--port 4096"*) return 0 ;;
  esac
  echo "expected defaults 127.0.0.1:4096, got: ${got:-<none>}"
  return 1
}

# Typed values must replace the defaults.
t_serve_prompt_accepts_input() {
  local tmp got
  command -v script >/dev/null 2>&1 || { echo "skip: script not available"; return 0; }
  tmp=$(mktemp -d)
  _serve_fixture "$tmp"
  printf '0.0.0.0\n5050\n' | script -qec "env HOME='$tmp' PATH='$tmp/bin:$PATH' '$SCRIPT' serve --bg" /dev/null >/dev/null 2>&1
  got=$(cat "$tmp/args" 2>/dev/null)
  _serve_cleanup "$tmp"
  case "$got" in
    *"--hostname 0.0.0.0"*"--port 5050"*) return 0 ;;
  esac
  echo "expected 0.0.0.0:5050, got: ${got:-<none>}"
  return 1
}

# Without a TTY (CI, scripts) serve must not block on a prompt.
t_serve_noninteractive_uses_defaults() {
  local tmp got
  tmp=$(mktemp -d)
  _serve_fixture "$tmp"
  ( unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
    HOME="$tmp" PATH="$tmp/bin:$PATH" "$SCRIPT" serve --bg </dev/null ) >/dev/null 2>&1
  got=$(cat "$tmp/args" 2>/dev/null)
  _serve_cleanup "$tmp"
  case "$got" in
    *"--hostname 127.0.0.1"*"--port 4096"*) return 0 ;;
  esac
  echo "expected defaults without prompting, got: ${got:-<none>}"
  return 1
}

echo
echo "zenreset tests"
check "version/help leave \$HOME untouched" t_readonly_no_side_effects
check "doctor stops a failed engine and its bridge" t_doctor_cleans_up_failed_engine
check "doctor skips warp-plus boot tests under proot" t_doctor_skips_warp_plus_under_proot
check "uninstall refuses without confirmation" t_uninstall_requires_confirmation
check "NO_COLOR output has no ANSI escapes" t_nocolor_output
check "serve prompt: Enter keeps defaults" t_serve_prompt_defaults_on_enter
check "serve prompt: typed host/port are used" t_serve_prompt_accepts_input
check "serve without a TTY uses defaults" t_serve_noninteractive_uses_defaults
echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
