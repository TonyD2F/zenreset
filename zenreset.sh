#!/usr/bin/env bash
# =============================================================================
# zenreset.sh — force-clear OpenCode Zen free-tier "Rate limit exceeded"
# Target: Debian (proot-distro) under Termux on Android, aarch64.
#
# WHY THIS WORKS: Zen keys the free-model limiter on your egress IP
# (anomalyco/opencode#34344). New WARP identity -> new exit IP -> fresh window.
# Bun has no SOCKS5 support, so warp-plus' SOCKS listener is bridged to HTTP
# via privoxy and handed to opencode through lowercase proxy env vars.
#
#   ./zenreset.sh install     one-time: deps + warp-plus binary
#   ./zenreset.sh start       bring up WARP + HTTP proxy
#   ./zenreset.sh status      pids, ports, current egress IP, zen verdict
#   ./zenreset.sh reset       rotate IP until Zen stops returning 429
#   ./zenreset.sh watch       poll Zen, auto-reset when limited
#   ./zenreset.sh shim        install an opencode wrapper that auto-proxies
#   ./zenreset.sh stop        tear down
#   ./zenreset.sh uninstall   remove binaries + config
# =============================================================================
set -uo pipefail

VERSION="1.0.0"

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zenreset"
CFG_FILE="$CFG_DIR/config.env"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zenreset"
BIN_DIR="$STATE_DIR/bin"
LOG_DIR="$STATE_DIR/log"
RUN_DIR="$STATE_DIR/run"
PRIVOXY_DIR="$CFG_DIR/privoxy"
PRIVOXY_CFG="$PRIVOXY_DIR/config"
WARP_CACHE="$STATE_DIR/warp"

mkdir -p "$CFG_DIR" "$STATE_DIR" "$BIN_DIR" "$LOG_DIR" "$RUN_DIR" "$PRIVOXY_DIR"

# ------------------------------- defaults -----------------------------------
: "${SOCKS_PORT:=18086}"
: "${HTTP_PORT:=18118}"
: "${MAX_ATTEMPTS:=8}"
: "${ATTEMPT_SLEEP:=3}"
: "${EXIT_MODE:=warp}"          # warp | psiphon | scan
: "${PSIPHON_COUNTRY:=US}"
: "${PROBE_ZEN:=1}"
: "${PROBE_MODEL:=deepseek-v4.1-flash-free}"
: "${CLEAR_CACHE:=1}"
: "${WATCH_INTERVAL:=60}"
: "${FORCE_NEW_IP:=1}"          # rotate again if egress IP is unchanged

[ -f "$CFG_FILE" ] && . "$CFG_FILE"

# -------------------------------- helpers -----------------------------------
c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_0=$'\033[0m'
log()  { printf '%s[zenreset]%s %s\n' "$c_b" "$c_0" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_y" "$c_0" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

pidfile() { echo "$RUN_DIR/$1.pid"; }

is_up() {  # is_up <name>
  local pf; pf=$(pidfile "$1")
  [ -f "$pf" ] || return 1
  local p; p=$(cat "$pf" 2>/dev/null) || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

stop_proc() { # stop_proc <name>
  local pf; pf=$(pidfile "$1")
  if is_up "$1"; then
    local p; p=$(cat "$pf")
    kill "$p" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$p" 2>/dev/null || break; sleep 0.25; done
    kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
    ok "stopped $1 (pid $p)"
  fi
  rm -f "$pf"
}

have() { command -v "$1" >/dev/null 2>&1; }

arch_tag() {
  case "$(uname -m)" in
    aarch64|arm64) echo arm64 ;;
    x86_64|amd64)  echo amd64 ;;
    armv7l|armv8l) echo armv7 ;;
    *) die "unsupported arch: $(uname -m)" ;;
  esac
}

WARP_BIN="$BIN_DIR/warp-plus"
PRIVOXY_BIN="$(command -v privoxy || echo /usr/sbin/privoxy)"

# ------------------------------ auth / probe --------------------------------
find_auth() {
  local c
  for c in \
    "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json" \
    "$HOME/.local/share/opencode/auth.json" \
    "$HOME/.config/opencode/auth.json" \
    "$HOME/.opencode/auth.json"; do
    [ -f "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

zen_key() {
  local f; f=$(find_auth) || return 1
  if have python3; then
    python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(next((v.get("key","") for k,v in d.items() if k=="opencode" or v.get("type")=="api"),""))' "$f" 2>/dev/null
  else
    sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n1
  fi
}

# returns: OK | LIMITED | UNKNOWN
zen_probe() {
  local key body code
  key=$(zen_key) || { echo UNKNOWN; return 0; }
  body=$(mktemp)
  code=$(curl -sS -m 45 -o "$body" -w '%{http_code}' \
      -x "http://127.0.0.1:$HTTP_PORT" \
      -A 'opencode/2.0' \
      -H "Authorization: Bearer $key" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$PROBE_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":4}" \
      "https://opencode.ai/inference/openai/v1/chat/completions" 2>/dev/null) || code=000
  local out=UNKNOWN
  if [ "$code" = "200" ]; then out=OK
  elif [ "$code" = "429" ]; then out=LIMITED
  elif grep -qi 'rate limit' "$body" 2>/dev/null; then out=LIMITED
  elif grep -qi 'FreeTierError' "$body" 2>/dev/null; then out=UNKNOWN
  fi
  rm -f "$body"
  echo "$out"
}

direct_ip() {
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
    curl -sS -m 12 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p'
}

egress_ip() {
  curl -sS -m 15 -x "http://127.0.0.1:$HTTP_PORT" \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p'
}

# ------------------------------- lifecycle ----------------------------------
ensure_deps() {
  local missing=()
  have curl   || missing+=(curl)
  have unzip  || missing+=(unzip)
  [ -x "$PRIVOXY_BIN" ] || missing+=(privoxy)
  have python3 || missing+=(python3)
  if [ ${#missing[@]} -gt 0 ]; then
    log "installing: ${missing[*]}"
    if have sudo && [ "$(id -u)" != "0" ]; then
      sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}"
    else
      apt-get update -qq && apt-get install -y "${missing[@]}"
    fi
  fi
  PRIVOXY_BIN="$(command -v privoxy || echo /usr/sbin/privoxy)"
  [ -x "$PRIVOXY_BIN" ] || die "privoxy not found after install"
}

fetch_warp() {
  [ -x "$WARP_BIN" ] && { ok "warp-plus already present"; return 0; }
  local tag url tmp
  tag=$(arch_tag)
  url="https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus_linux-${tag}.zip"
  tmp=$(mktemp -d)
  log "downloading warp-plus (linux-$tag)"
  curl -fL --retry 3 -o "$tmp/w.zip" "$url" || die "download failed: $url"
  unzip -oq "$tmp/w.zip" -d "$tmp" || die "unzip failed"
  local found; found=$(find "$tmp" -type f -name 'warp-plus*' ! -name '*.zip' ! -name '*.dgst' | head -n1)
  [ -n "$found" ] || die "binary not found in archive"
  install -m 0755 "$found" "$WARP_BIN"
  rm -rf "$tmp"
  ok "warp-plus -> $WARP_BIN"
}

write_privoxy_cfg() {
  cat > "$PRIVOXY_CFG" <<EOF
# generated by zenreset.sh
confdir $PRIVOXY_DIR
logdir  $LOG_DIR
listen-address 127.0.0.1:$HTTP_PORT
forward-socks5t / 127.0.0.1:$SOCKS_PORT .
buffer-limit 16384
keep-alive-timeout 30
socket-timeout 120
connection-sharing 1
enable-remote-toggle 0
enable-edit-actions 0
EOF
}

start_warp() {
  is_up warp && return 0
  write_privoxy_cfg
  local args=(--bind "127.0.0.1:$SOCKS_PORT" --cache-dir "$WARP_CACHE" --dns 1.1.1.1)
  case "$EXIT_MODE" in
    psiphon) args+=(--cfon --country "$PSIPHON_COUNTRY") ;;
    scan)    args+=(--scan) ;;
  esac
  log "starting warp-plus (mode=$EXIT_MODE, socks=127.0.0.1:$SOCKS_PORT)"
  nohup "$WARP_BIN" "${args[@]}" >"$LOG_DIR/warp.log" 2>&1 &
  echo $! > "$(pidfile warp)"
  sleep 2
  is_up warp || { tail -n 30 "$LOG_DIR/warp.log" >&2; die "warp-plus died"; }
  ok "warp-plus up (pid $(cat "$(pidfile warp)"))"
}

start_bridge() {
  is_up privoxy && return 0
  log "starting privoxy (http=127.0.0.1:$HTTP_PORT)"
  nohup "$PRIVOXY_BIN" --no-daemon "$PRIVOXY_CFG" >"$LOG_DIR/privoxy.log" 2>&1 &
  echo $! > "$(pidfile privoxy)"
  sleep 1
  is_up privoxy || { tail -n 20 "$LOG_DIR/privoxy.log" >&2; die "privoxy died"; }
  ok "privoxy up (pid $(cat "$(pidfile privoxy)"))"
}

wait_for_proxy() {
  local i
  for i in $(seq 1 40); do
    if curl -sS -m 6 -x "http://127.0.0.1:$HTTP_PORT" \
        -o /dev/null https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

rotate() {
  log "rotating WARP identity (new registration)"
  stop_proc warp
  rm -rf "$WARP_CACHE"
  mkdir -p "$WARP_CACHE"
  start_warp
  start_bridge
  if ! wait_for_proxy; then warn "proxy did not come up in time"; fi
}

clear_local_state() {
  [ "$CLEAR_CACHE" = "1" ] || return 0
  local d
  for d in "${XDG_CACHE_HOME:-$HOME/.cache}/opencode" \
           "$HOME/.cache/opencode" \
           "$HOME/.local/state/opencode/cache"; do
    [ -d "$d" ] && { rm -rf "$d"; log "cleared $d"; }
  done
  # provider/model catalogue cache only — auth.json is preserved
  rm -rf "$HOME/.local/share/opencode/cache" 2>/dev/null || true
}

write_env_file() {
  cat > "$CFG_DIR/proxy.env" <<EOF
# source me: . "$CFG_DIR/proxy.env"
# lowercase is what opencode actually honours (anomalyco/opencode#6953)
export http_proxy="http://127.0.0.1:$HTTP_PORT"
export https_proxy="http://127.0.0.1:$HTTP_PORT"
export HTTP_PROXY="\$http_proxy"
export HTTPS_PROXY="\$https_proxy"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="\$no_proxy"
EOF
  ok "wrote $CFG_DIR/proxy.env"
}

# -------------------------------- commands ----------------------------------
cmd_install() { ensure_deps; fetch_warp; write_privoxy_cfg; ok "install complete"; }

cmd_start() {
  ensure_deps; fetch_warp
  start_warp; start_bridge
  wait_for_proxy || warn "proxy unreachable"
  write_env_file
  cmd_status
}

cmd_stop() { stop_proc privoxy; stop_proc warp; ok "all stopped"; }

cmd_status() {
  echo
  log "binaries : $([ -x "$WARP_BIN" ] && echo present || echo MISSING)  /  $PRIVOXY_BIN"
  log "warp-plus: $(is_up warp     && echo "up (pid $(cat "$(pidfile warp)"))"     || echo down)"
  log "privoxy  : $(is_up privoxy  && echo "up (pid $(cat "$(pidfile privoxy)"))"  || echo down)"
  local dip eip
  dip=$(direct_ip); eip=$(egress_ip)
  log "direct IP: ${dip:-<none>}"
  log "proxy  IP: ${eip:-<none>}"
  [ -n "$dip" ] && [ -n "$eip" ] && [ "$dip" = "$eip" ] && warn "egress IP equals direct IP — WARP may not be tunnelling"
  if is_up privoxy && [ -n "$eip" ]; then
    log "zen probe: $(zen_probe)  (model $PROBE_MODEL)"
  fi
  echo
}

cmd_reset() {
  ensure_deps; fetch_warp; write_env_file
  local tries=0 prev_ip cur_ip verdict
  prev_ip=$(egress_ip 2>/dev/null || echo "")
  while [ "$tries" -lt "$MAX_ATTEMPTS" ]; do
    tries=$((tries + 1))
    log "attempt $tries/$MAX_ATTEMPTS"
    rotate
    cur_ip=$(egress_ip 2>/dev/null || echo "")
    if [ -z "$cur_ip" ]; then warn "no egress IP yet"; sleep "$ATTEMPT_SLEEP"; continue; fi
    if [ "$FORCE_NEW_IP" = "1" ] && [ "$cur_ip" = "$prev_ip" ]; then
      warn "egress IP unchanged ($cur_ip) — re-rotating"
      prev_ip="$cur_ip"; continue
    fi
    prev_ip="$cur_ip"
    ok "egress IP -> $cur_ip"
    if [ "$PROBE_ZEN" = "1" ]; then
      verdict=$(zen_probe)
      log "zen probe: $verdict"
      case "$verdict" in
        OK)      ok "limit cleared on $cur_ip"; clear_local_state; cmd_status; return 0 ;;
        LIMITED) warn "still limited on $cur_ip"; sleep "$ATTEMPT_SLEEP"; continue ;;
        *)       warn "inconclusive probe; assuming cleared"; clear_local_state; return 0 ;;
      esac
    else
      clear_local_state; return 0
    fi
  done
  warn "gave up after $MAX_ATTEMPTS rotations."
  warn "if every fresh IP 429s, you are likely on the per-account daily quota, not the IP limiter."
  return 1
}

cmd_watch() {
  log "watching every ${WATCH_INTERVAL}s (ctrl-c to stop)"
  while :; do
    if is_up privoxy && is_up warp; then
      local v; v=$(zen_probe)
      if [ "$v" = "LIMITED" ]; then
        log "429 detected — resetting"
        cmd_reset || true
      fi
    else
      warn "stack down — starting"
      cmd_start >/dev/null 2>&1 || true
    fi
    sleep "$WATCH_INTERVAL"
  done
}

cmd_shim() {
  local real
  real=$(command -v opencode) || die "opencode not on PATH"
  [ "$real" = "$HOME/.local/bin/opencode" ] && real=$(readlink -f "$real")
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/opencode" <<EOF
#!/usr/bin/env bash
# zenreset shim — routes opencode through the local WARP egress
[ -f "$CFG_DIR/proxy.env" ] && . "$CFG_DIR/proxy.env"
exec "$real" "\$@"
EOF
  chmod +x "$HOME/.local/bin/opencode"
  ok "shim -> $HOME/.local/bin/opencode (wraps $real)"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) : ;;
    *) warn "add to PATH:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac
}

cmd_uninstall() {
  cmd_stop
  rm -rf "$STATE_DIR" "$CFG_DIR"
  ok "removed $STATE_DIR and $CFG_DIR"
}

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-help}" in
  install)   cmd_install ;;
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  status)    cmd_status ;;
  reset)     cmd_reset ;;
  watch)     cmd_watch ;;
  shim)      cmd_shim ;;
  uninstall) cmd_uninstall ;;
  version)   echo "$VERSION" ;;
  *)         usage ;;
esac
