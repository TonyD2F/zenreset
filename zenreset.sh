#!/usr/bin/env bash
# =============================================================================
# zenreset.sh — force-clear OpenCode Zen free-tier "Rate limit exceeded"
# Target: Debian (proot-distro) under Termux on Android, aarch64.
#
# Zen keys the free-model limiter on egress IP (anomalyco/opencode#34344).
# New WARP identity -> new exit IP -> fresh window.
#
# ENGINE NOTES (proot reality, confirmed by `doctor`):
#   warp-plus-*    vendored wireguard-go; SO_RCVBUFFORCE/SO_SNDBUFFORCE return
#                  EPERM under proot (no CAP_NET_ADMIN) and its bind code does
#                  not fall back -> device dies -> panic. Both builds affected.
#   usque          MASQUE/QUIC, no wireguard-go, unaffected. DEFAULT.
#   cloudflare-warp kept as a third option.
#
#   ./zenreset.sh doctor           install engines, probe sockets, boot-test
#   ./zenreset.sh reset            rotate until clear, then opencode serve
#   ./zenreset.sh reset --bg       same, daemonised
#   ./zenreset.sh reset --engine X force one engine
#   ./zenreset.sh serve            (re)start opencode serve via the proxy
#   ./zenreset.sh start|status|stop
#   ./zenreset.sh watch            poll Zen, auto-reset + auto-serve
#   ./zenreset.sh shim             opencode wrapper that auto-proxies
#   ./zenreset.sh link             install an `oc` shortcut on PATH
# =============================================================================
set -uo pipefail

VERSION="1.5.1"

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zenreset"
CFG_FILE="$CFG_DIR/config.env"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zenreset"
BIN_DIR="$STATE_DIR/bin"
LOG_DIR="$STATE_DIR/log"
RUN_DIR="$STATE_DIR/run"
PRIVOXY_DIR="$CFG_DIR/privoxy"
PRIVOXY_CFG="$PRIVOXY_DIR/config"
REAL_FILE="$CFG_DIR/opencode.real"
WORKING_FILE="$CFG_DIR/engine.working"

ensure_dirs() { mkdir -p "$CFG_DIR" "$STATE_DIR" "$BIN_DIR" "$LOG_DIR" "$RUN_DIR" "$PRIVOXY_DIR"; }

# ------------------------------- defaults -----------------------------------
: "${SOCKS_PORT:=18086}"
: "${HTTP_PORT:=18118}"
: "${MAX_ATTEMPTS:=6}"
: "${ATTEMPT_SLEEP:=3}"
# usque first: the only engine that survives proot's missing CAP_NET_ADMIN
: "${ENGINES:=usque warp-plus-linux warp-plus-android cloudflare-warp}"
: "${ENGINE:=}"
: "${EXIT_MODE:=warp}"
: "${PSIPHON_COUNTRY:=US}"
: "${WARP_EXTRA_ARGS:=-4}"
: "${WARP_TUN:=0}"
: "${PROBE_ZEN:=1}"
: "${PROBE_MODEL:=deepseek-v4.1-flash-free}"
: "${CLEAR_CACHE:=1}"
: "${WATCH_INTERVAL:=60}"
: "${FORCE_NEW_IP:=1}"
: "${ENGINE_BOOT_WAIT:=6}"
: "${PROXY_WAIT:=30}"

: "${SERVE_AUTOSTART:=1}"
: "${SERVE_BACKGROUND:=0}"
: "${SERVE_HOST:=127.0.0.1}"
: "${SERVE_PORT:=4096}"
: "${SERVE_ARGS:=}"
: "${SERVE_WAIT:=3}"
: "${SERVE_RESTART_ON_RESET:=1}"

# shellcheck disable=SC1090
[ -f "$CFG_FILE" ] && . "$CFG_FILE"

# -------------------------------- helpers -----------------------------------
c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[36m'; c_0=$'\033[0m'
if [ -n "${NO_COLOR+x}" ] || [ ! -t 1 ]; then
  c_r=''; c_g=''; c_y=''; c_b=''; c_0=''
fi
log()  { printf '%s[zenreset]%s %s\n' "$c_b" "$c_0" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$c_g" "$c_0" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_y" "$c_0" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }

pidfile() { echo "$RUN_DIR/$1.pid"; }
have()    { command -v "$1" >/dev/null 2>&1; }
on_path() { case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac; }

is_up() {
  local pf; pf=$(pidfile "$1"); [ -f "$pf" ] || return 1
  local p; p=$(cat "$pf" 2>/dev/null) || return 1
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

stop_proc() {
  local pf; pf=$(pidfile "$1")
  if is_up "$1"; then
    local p; p=$(cat "$pf")
    kill "$p" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$p" 2>/dev/null || break; sleep 0.25; done
    kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
  fi
  rm -f "$pf"
}

arch_tag() {
  case "$(uname -m)" in
    aarch64|arm64) echo arm64 ;;
    x86_64|amd64)  echo amd64 ;;
    armv7l|armv8l) echo armv7 ;;
    *) die "unsupported arch: $(uname -m)" ;;
  esac
}

ipv6_missing() { [ ! -f /proc/net/if_inet6 ]; }

PRIVOXY_BIN="$(command -v privoxy || echo /usr/sbin/privoxy)"
engine_is_direct() { [ "$1" = "cloudflare-warp" ]; }

# working engine first, then the rest of the configured order
engine_order() {
  local list="${ENGINE:-$ENGINES}" cached="" out="" e
  if [ -z "$ENGINE" ] && [ -s "$WORKING_FILE" ]; then
    cached=$(cat "$WORKING_FILE")
    case " $list " in *" $cached "*) out="$cached" ;; esac
  fi
  for e in $list; do
    [ "$e" = "$out" ] && continue
    out="${out:+$out }$e"
  done
  printf '%s\n' "$out"
}

# ------------------------------ engine bins ---------------------------------
engine_bin() {
  case "$1" in
    warp-plus-linux)   echo "$BIN_DIR/warp-plus-linux" ;;
    warp-plus-android) echo "$BIN_DIR/warp-plus-android" ;;
    cloudflare-warp)   echo "$BIN_DIR/cloudflare-warp" ;;
    usque)             echo "$BIN_DIR/usque" ;;
    *)                 echo "" ;;
  esac
}
engine_state_dir() { echo "$STATE_DIR/engines/$1"; }

gh_release_json() { curl -sSL --max-time 25 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null; }

gh_asset_url() { # repo pattern...
  local repo="$1"; shift
  local json; json=$(gh_release_json "$repo")
  [ -n "$json" ] || return 1
  local urls pat hit
  urls=$(printf '%s' "$json" | grep -o '"browser_download_url":[^,]*' \
       | sed 's/.*"\(https:[^"]*\)".*/\1/' \
       | grep -Eiv '\.(dgst|sig|sha256|sbom|json|txt)$')
  [ -n "$urls" ] || return 1
  for pat in "$@"; do
    hit=$(printf '%s\n' "$urls" | grep -Ei "$pat" | head -n1)
    [ -n "$hit" ] && { echo "$hit"; return 0; }
  done
  return 1
}

gh_asset_names() { # repo - for debugging
  gh_release_json "$1" | grep -o '"name":[^,]*' | sed 's/.*"\([^"]*\)".*/\1/' | head -n 12
}

install_asset() {
  local url="$1" dest="$2" tmp; tmp=$(mktemp -d)
  log "fetching $(basename "$url")"
  curl -fL --retry 3 --max-time 300 -o "$tmp/a" "$url" || { rm -rf "$tmp"; return 1; }
  case "$url" in
    *.zip)          unzip -oq "$tmp/a" -d "$tmp" || { rm -rf "$tmp"; return 1; } ;;
    *.tar.gz|*.tgz) tar -xzf "$tmp/a" -C "$tmp" || { rm -rf "$tmp"; return 1; } ;;
    *.tar.xz)       tar -xJf "$tmp/a" -C "$tmp" || { rm -rf "$tmp"; return 1; } ;;
  esac
  local f; f=$(find "$tmp" -type f -perm -u+x ! -name '*.zip' ! -name '*.tar.*' \
                 ! -name '*.dgst' ! -name '*.sig' 2>/dev/null | head -n1)
  [ -z "$f" ] && f="$tmp/a"
  install -m 0755 "$f" "$dest" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

fetch_engine() {
  local e="$1" bin; bin=$(engine_bin "$e")
  [ -n "$bin" ] || { warn "unknown engine: $e"; return 1; }

  if [ ! -x "$bin" ] && [ -x "$BIN_DIR/warp-plus" ] && [ "$e" = "warp-plus-linux" ]; then
    mv "$BIN_DIR/warp-plus" "$bin" && ok "migrated legacy warp-plus -> $bin" && return 0
  fi
  [ -x "$bin" ] && return 0

  local tag; tag=$(arch_tag); local url="" repo=""
  case "$e" in
    warp-plus-linux)
      url="https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus_linux-${tag}.zip" ;;
    warp-plus-android)
      url="https://github.com/bepass-org/warp-plus/releases/latest/download/warp-plus_android-${tag}.zip" ;;
    usque)
      repo="Diniboy1123/usque"
      url=$(gh_asset_url "$repo" "linux[-_.]?${tag}" "${tag}.*linux" "linux" ) || true ;;
    cloudflare-warp)
      repo="shahradelahi/cloudflare-warp"
      url=$(gh_asset_url "$repo" "linux[-_.]?${tag}" "linux[-_.]?aarch64" "${tag}" ) || true ;;
  esac
  if [ -z "$url" ]; then
    warn "$e: no linux-$tag asset matched"
    if [ -n "$repo" ]; then
      local names; names=$(gh_asset_names "$repo")
      [ -n "$names" ] && printf '%s\n' "$names" | sed 's/^/         - /' >&2
    fi
    return 1
  fi
  install_asset "$url" "$bin" || { warn "$e: install failed"; return 1; }
  ok "$e -> $bin"
}

fetch_all_engines() { local e; for e in $(engine_order); do fetch_engine "$e" || true; done; }

# ------------------------------ auth / probe --------------------------------
find_auth() {
  local c
  for c in "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json" \
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

zen_probe() {
  local key body code
  key=$(zen_key) || { echo UNKNOWN; return 0; }
  body=$(mktemp)
  code=$(curl -sS -m 45 -o "$body" -w '%{http_code}' \
      -x "http://127.0.0.1:$HTTP_PORT" -A 'opencode/2.0' \
      -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$PROBE_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":4}" \
      "https://opencode.ai/inference/openai/v1/chat/completions" 2>/dev/null) || code=000
  local out=UNKNOWN
  if   [ "$code" = "200" ]; then out=OK
  elif [ "$code" = "429" ]; then out=LIMITED
  elif grep -qi 'rate limit' "$body" 2>/dev/null; then out=LIMITED
  fi
  rm -f "$body"; echo "$out"
}

direct_ip() {
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
    curl -sS -m 12 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p'
}
egress_ip() {
  curl -sS -m 15 -x "http://127.0.0.1:$HTTP_PORT" \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p'
}

# ------------------------------ engine launch -------------------------------
write_privoxy_cfg() {
  cat > "$PRIVOXY_CFG" <<EOF
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

engine_args() {
  case "$1" in
    warp-plus-linux|warp-plus-android)
      # shellcheck disable=SC2155
      local a="--bind 127.0.0.1:$SOCKS_PORT --cache-dir $(engine_state_dir "$1") --dns 1.1.1.1"
      [ -n "$WARP_EXTRA_ARGS" ] && a="$a $WARP_EXTRA_ARGS"
      [ "$WARP_TUN" = "1" ] && a="$a --tun-experimental"
      case "$EXIT_MODE" in
        psiphon) a="$a --cfon --country $PSIPHON_COUNTRY" ;;
        scan)    a="$a --scan" ;;
      esac
      echo "$a" ;;
    cloudflare-warp)
      echo "run --socks-addr 127.0.0.1:$SOCKS_PORT --http-addr 127.0.0.1:$HTTP_PORT" ;;
    usque)
      echo "socks -p $SOCKS_PORT --config $(engine_state_dir usque)/config.json" ;;
  esac
}

engine_prepare() {
  local e="$1" d; d=$(engine_state_dir "$e"); mkdir -p "$d"
  if [ "$e" = "usque" ] && [ ! -f "$d/config.json" ]; then
    log "usque: registering WARP account"
    "$(engine_bin usque)" register --config "$d/config.json" --accept-tos \
      >"$LOG_DIR/usque-register.log" 2>&1 || warn "usque register failed (see log)"
  fi
}

start_engine() {
  local e="$1" bin; bin=$(engine_bin "$e")
  [ -x "$bin" ] || { warn "$e not installed"; return 1; }
  stop_proc engine
  engine_prepare "$e"

  local lf="$LOG_DIR/engine-$e.log"
  local args; args=$(engine_args "$e")
  log "starting engine=$e  ($args)"
  # shellcheck disable=SC2086
  nohup "$bin" $args >"$lf" 2>&1 &
  echo $! > "$(pidfile engine)"
  sleep "$ENGINE_BOOT_WAIT"

  if ! is_up engine; then
    warn "$e died during boot:"; tail -n 5 "$lf" 2>/dev/null >&2; return 1
  fi
  if grep -q 'panic:' "$lf" 2>/dev/null; then
    warn "$e panicked (log: $lf)"; stop_proc engine; return 1
  fi
  ok "$e up (pid $(cat "$(pidfile engine)"))"
}

start_bridge() {
  local e="$1"
  engine_is_direct "$e" && { stop_proc privoxy; return 0; }
  is_up privoxy && return 0
  write_privoxy_cfg
  nohup "$PRIVOXY_BIN" --no-daemon "$PRIVOXY_CFG" >"$LOG_DIR/privoxy.log" 2>&1 &
  echo $! > "$(pidfile privoxy)"
  sleep 1
  is_up privoxy || { warn "privoxy died"; tail -n 10 "$LOG_DIR/privoxy.log" >&2; return 1; }
}

wait_for_proxy() {
  local i
  # shellcheck disable=SC2034
  for i in $(seq 1 "$PROXY_WAIT"); do
    is_up engine || return 1
    curl -sS -m 6 -x "http://127.0.0.1:$HTTP_PORT" \
      -o /dev/null https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

bring_up() {
  local e="$1"
  start_engine "$e" || return 1
  start_bridge "$e" || return 1
  if ! wait_for_proxy; then
    warn "$e: engine alive but no egress after ${PROXY_WAIT}s — last log lines:"
    tail -n 6 "$LOG_DIR/engine-$e.log" 2>/dev/null >&2
    return 1
  fi
  echo "$e" > "$WORKING_FILE"
  return 0
}

# ------------------------------- stack ops ----------------------------------
ensure_deps() {
  local missing=()
  have curl || missing+=(curl); have unzip || missing+=(unzip)
  [ -x "$PRIVOXY_BIN" ] || missing+=(privoxy)
  have python3 || missing+=(python3)
  if [ ${#missing[@]} -gt 0 ]; then
    log "installing: ${missing[*]}"
    # shellcheck disable=SC2015
    apt-get update -qq && apt-get install -y "${missing[@]}" || die "apt failed"
  fi
  PRIVOXY_BIN="$(command -v privoxy || echo /usr/sbin/privoxy)"
}

write_env_file() {
  cat > "$CFG_DIR/proxy.env" <<EOF
export http_proxy="http://127.0.0.1:$HTTP_PORT"
export https_proxy="http://127.0.0.1:$HTTP_PORT"
export HTTP_PROXY="\$http_proxy"
export HTTPS_PROXY="\$https_proxy"
export no_proxy="localhost,127.0.0.1,::1"
export NO_PROXY="\$no_proxy"
EOF
}

clear_local_state() {
  [ "$CLEAR_CACHE" = "1" ] || return 0
  local d
  for d in "${XDG_CACHE_HOME:-$HOME/.cache}/opencode" "$HOME/.cache/opencode"; do
    [ -d "$d" ] && { rm -rf "$d"; log "cleared $d"; }
  done
}

# -------------------------------- serve -------------------------------------
real_opencode() {
  if [ -s "$REAL_FILE" ]; then
    local p; p=$(cat "$REAL_FILE"); [ -x "$p" ] && { echo "$p"; return 0; }
  fi
  local p
  for p in $(type -ap opencode 2>/dev/null); do
    grep -qs 'zenreset shim' "$p" 2>/dev/null && continue
    echo "$p"; return 0
  done
  command -v opencode 2>/dev/null
}

start_serve() {
  local mode="${1:-auto}"
  [ "$SERVE_AUTOSTART" = "1" ] || return 0
  [ "$mode" = "auto" ] && mode=$([ "$SERVE_BACKGROUND" = "1" ] && echo bg || echo fg)

  local bin; bin=$(real_opencode)
  # shellcheck disable=SC2015
  [ -n "$bin" ] && [ -x "$bin" ] || { warn "opencode not on PATH — skipping serve"; return 0; }

  if is_up serve; then
    if [ "$SERVE_RESTART_ON_RESET" = "1" ]; then stop_proc serve
    else [ "$mode" = bg ] && { ok "serve already running"; return 0; }; fi
  fi

  # shellcheck disable=SC1091
  . "$CFG_DIR/proxy.env" 2>/dev/null || true
  local args=()
  [ -n "$SERVE_HOST" ] && args+=(--hostname "$SERVE_HOST")
  [ -n "$SERVE_PORT" ] && args+=(--port "$SERVE_PORT")
  if [ -n "$SERVE_ARGS" ]; then local x; read -r -a x <<< "$SERVE_ARGS"; args+=("${x[@]}"); fi
  local url="http://${SERVE_HOST}:${SERVE_PORT}"

  if [ "$mode" = bg ]; then
    log "starting opencode serve (bg) -> $url"
    nohup "$bin" serve "${args[@]}" >"$LOG_DIR/serve.log" 2>&1 &
    echo $! > "$(pidfile serve)"
    sleep "$SERVE_WAIT"
    if is_up serve; then ok "serve up (pid $(cat "$(pidfile serve)")) -> $url"
    else warn "serve exited; tail:"; tail -n 15 "$LOG_DIR/serve.log" >&2; rm -f "$(pidfile serve)"; fi
  else
    ok "starting opencode serve (fg) -> $url  (ctrl-c to stop)"
    exec "$bin" serve "${args[@]}"
  fi
}

# -------------------------------- commands ----------------------------------
cmd_install() { ensure_deps; fetch_all_engines; write_privoxy_cfg; write_env_file; ok "install complete"; }

cmd_doctor() {
  echo
  log "arch      : $(uname -m)  (asset tag: $(arch_tag))"
  log "kernel    : $(uname -r)"
  log "/dev/net/tun: $([ -e /dev/net/tun ] && echo present || echo MISSING)"
  log "ipv6      : $(ipv6_missing && echo MISSING || echo available)"
  log "privoxy   : $PRIVOXY_BIN $([ -x "$PRIVOXY_BIN" ] && echo ok || echo MISSING)"
  [ -s "$WORKING_FILE" ] && log "cached engine: $(cat "$WORKING_FILE")"
  echo

  if [ "${DOCTOR_FETCH:-1}" = "1" ]; then
    log "fetching engines (skip with --no-fetch)"
    fetch_all_engines
    echo
  fi

  log "engines:"
  local e b
  for e in $(engine_order); do
    b=$(engine_bin "$e")
    printf '  %-20s %s\n' "$e" "$([ -x "$b" ] && echo present || echo missing)"
  done
  echo

  if have python3; then
    log "socket option probe (what listenNet() does after bind):"
    python3 - <<'PY'
import socket
SO_RCVBUFFORCE, SO_SNDBUFFORCE = 33, 32
IP_PKTINFO, IP_MTU_DISCOVER = 8, 10
IPV6_RECVPKTINFO, IPV6_RECVHOPLIMIT, IPV6_MTU_DISCOVER = 49, 51, 23
IP_PMTUDISC_DO = 2

def probe(label, fam, lvl, opt, addr, val=1):
    try:
        s = socket.socket(fam, socket.SOCK_DGRAM); s.bind(addr)
    except OSError as e:
        print(f'  {label:<28} BIND FAILED -> {e}'); return
    try:
        s.setsockopt(lvl, opt, val); print(f'  {label:<28} ok')
    except OSError as e:
        print(f'  {label:<28} FAILED -> {e}')
    finally:
        s.close()

probe('udp4 SO_RCVBUFFORCE',   socket.AF_INET,  socket.SOL_SOCKET,   SO_RCVBUFFORCE,   ('', 0))
probe('udp4 SO_SNDBUFFORCE',   socket.AF_INET,  socket.SOL_SOCKET,   SO_SNDBUFFORCE,   ('', 0))
probe('udp4 IP_PKTINFO',       socket.AF_INET,  socket.IPPROTO_IP,   IP_PKTINFO,       ('', 0))
probe('udp4 IP_MTU_DISCOVER',  socket.AF_INET,  socket.IPPROTO_IP,   IP_MTU_DISCOVER,  ('', 0), IP_PMTUDISC_DO)
probe('udp6 SO_RCVBUFFORCE',   socket.AF_INET6, socket.SOL_SOCKET,   SO_RCVBUFFORCE,   ('::', 0))
probe('udp6 IPV6_RECVPKTINFO', socket.AF_INET6, socket.IPPROTO_IPV6, IPV6_RECVPKTINFO, ('::', 0))
probe('udp6 IPV6_RECVHOPLIMIT',socket.AF_INET6, socket.IPPROTO_IPV6, IPV6_RECVHOPLIMIT,('::', 0))
probe('udp6 IPV6_MTU_DISCOVER',socket.AF_INET6, socket.IPPROTO_IPV6, IPV6_MTU_DISCOVER,('::', 0), IP_PMTUDISC_DO)
PY
    echo
  fi

  log "engine boot test (${ENGINE_BOOT_WAIT}s each, no rotation):"
  # Never leave a bridge or engine behind, whether the test passes, fails, or
  # is interrupted.
  trap 'stop_proc privoxy; stop_proc engine; exit 130' INT TERM
  for e in $(engine_order); do
    [ -x "$(engine_bin "$e")" ] || continue
    if bring_up "$e"; then
      ok "  $e: SURVIVED, egress $(egress_ip || echo '<none>')"
    else
      warn "  $e: FAILED"
    fi
    stop_proc privoxy; stop_proc engine
  done
  trap - INT TERM
  echo
  [ -s "$WORKING_FILE" ] && ok "working engine cached: $(cat "$WORKING_FILE")"
  echo
}

cmd_start() {
  ensure_deps; write_env_file
  local e
  for e in $(engine_order); do
    fetch_engine "$e" || true
    if bring_up "$e"; then ok "stack up via $e"; cmd_status; return 0; fi
    warn "$e failed — trying next"
  done
  die "no engine could start. run: ./zenreset.sh doctor"
}

cmd_stop() { stop_proc serve; stop_proc privoxy; stop_proc engine; ok "all stopped"; }

cmd_status() {
  echo
  log "engine   : $(is_up engine && echo "up (pid $(cat "$(pidfile engine)"))" || echo down)  (cached: $([ -s "$WORKING_FILE" ] && cat "$WORKING_FILE" || echo none))"
  log "privoxy  : $(is_up privoxy && echo "up" || echo down)"
  log "serve    : $(is_up serve && echo "up (pid $(cat "$(pidfile serve)"))" || echo down)"
  log "direct IP: $(direct_ip || echo '<none>')"
  log "proxy  IP: $(egress_ip || echo '<none>')"
  is_up privoxy && log "zen probe: $(zen_probe)"
  echo
}

cmd_reset() {
  ensure_deps; write_env_file
  local prev_ip; prev_ip=$(egress_ip 2>/dev/null || echo "")
  local any_up=0 e

  for e in $(engine_order); do
    fetch_engine "$e" || continue
    local tries=0
    while [ "$tries" -lt "$MAX_ATTEMPTS" ]; do
      tries=$((tries + 1))
      log "engine=$e  attempt $tries/$MAX_ATTEMPTS"

      stop_proc engine; stop_proc privoxy
      rm -rf "$(engine_state_dir "$e")"; mkdir -p "$(engine_state_dir "$e")"

      bring_up "$e" || { warn "$e unusable, moving on"; break; }
      any_up=1

      local cur; cur=$(egress_ip 2>/dev/null || echo "")
      if [ -z "$cur" ]; then warn "no egress IP"; sleep "$ATTEMPT_SLEEP"; continue; fi
      if [ "$FORCE_NEW_IP" = "1" ] && [ "$cur" = "$prev_ip" ]; then
        warn "egress unchanged ($cur)"; prev_ip="$cur"; continue
      fi
      prev_ip="$cur"; ok "egress IP -> $cur"

      if [ "$PROBE_ZEN" = "1" ]; then
        local v; v=$(zen_probe); log "zen probe: $v"
        case "$v" in
          OK) ok "limit cleared on $cur via $e"
              clear_local_state; cmd_status; start_serve; return 0 ;;
          LIMITED) warn "still limited on $cur"; sleep "$ATTEMPT_SLEEP"; continue ;;
          *) warn "inconclusive probe; assuming cleared"
             clear_local_state; cmd_status; start_serve; return 0 ;;
        esac
      else
        clear_local_state; start_serve; return 0
      fi
    done
  done

  warn "exhausted every engine / attempt."
  warn "if every fresh IP 429s you're on the per-account daily quota, not the IP limiter."
  [ "$any_up" = "1" ] && start_serve
  return 1
}

cmd_serve() { ensure_deps; write_env_file; is_up engine || cmd_start; start_serve; }

cmd_watch() {
  log "watching every ${WATCH_INTERVAL}s"
  while :; do
    if is_up privoxy || is_up engine; then
      local v; v=$(zen_probe)
      if [ "$v" = "LIMITED" ]; then log "429 — resetting"; cmd_reset || true
      elif [ "$SERVE_AUTOSTART" = "1" ] && ! is_up serve; then start_serve bg; fi
    else
      warn "stack down — starting"; cmd_start >/dev/null 2>&1 || true
    fi
    sleep "$WATCH_INTERVAL"
  done
}

cmd_shim() {
  local real; real=$(real_opencode) || die "opencode not on PATH"
  echo "$real" > "$REAL_FILE"
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/opencode" <<EOF
#!/usr/bin/env bash
# zenreset shim — routes opencode through the local WARP egress
[ -f "$CFG_DIR/proxy.env" ] && . "$CFG_DIR/proxy.env"
exec "$real" "\$@"
EOF
  chmod +x "$HOME/.local/bin/opencode"
  ok "shim -> $HOME/.local/bin/opencode (wraps $real)"
}

cmd_forget() { rm -f "$WORKING_FILE"; ok "cleared cached engine"; }

self_path() {
  local s="$0"
  if have readlink; then
    local r; r=$(readlink -f "$s" 2>/dev/null) && [ -n "$r" ] && s="$r"
  fi
  case "$s" in
    /*) printf '%s\n' "$s" ;;
    *)  printf '%s/%s\n' "$(pwd)" "${s#./}" ;;
  esac
}

cmd_link() {
  local script; script=$(self_path)
  [ -f "$script" ] || die "cannot resolve own path"

  local dir
  if [ -w /usr/local/bin ] && on_path /usr/local/bin; then
    dir=/usr/local/bin
  else
    dir="$HOME/.local/bin"; mkdir -p "$dir"
  fi

  cat > "$dir/oc" <<EOF
#!/usr/bin/env bash
# oc — shortcut for zenreset.sh  (installed by: zenreset.sh link)
ZENRESET="\${ZENRESET:-$script}"
[ -x "\$ZENRESET" ] || { echo "oc: zenreset.sh not found at \$ZENRESET" >&2
                        echo "    set ZENRESET=/path/to/zenreset.sh" >&2; exit 1; }
cd "\$(dirname "\$ZENRESET")" || exit 1

case "\${1:-}" in
  r|reset)      shift; exec "\$ZENRESET" reset  "\$@" ;;
  d|doc|doctor) shift; exec "\$ZENRESET" doctor "\$@" ;;
  s|st|status)  shift; exec "\$ZENRESET" status "\$@" ;;
  v|serve)      shift; exec "\$ZENRESET" serve  "\$@" ;;
  w|watch)      shift; exec "\$ZENRESET" watch  "\$@" ;;
  up|start)     shift; exec "\$ZENRESET" start  "\$@" ;;
  down|stop)    shift; exec "\$ZENRESET" stop   "\$@" ;;
  f|forget)     shift; exec "\$ZENRESET" forget "\$@" ;;
  h|help)       exec "\$ZENRESET" help ;;
  "")           exec "\$ZENRESET" reset ;;
  *)            exec "\$ZENRESET" "\$@" ;;
esac
EOF
  chmod +x "$dir/oc"
  ok "installed $dir/oc  ->  $script"

  on_path "$dir" || warn "$dir is not on PATH. add:  export PATH=\"$dir:\$PATH\""
  echo
  log "try: oc status   |   oc doctor   |   oc reset   |   oc reset --bg"
}

cmd_unlink() {
  local p
  for p in /usr/local/bin/oc "$HOME/.local/bin/oc"; do
    if [ -f "$p" ] && grep -qs 'shortcut for zenreset' "$p"; then
      rm -f "$p"; ok "removed $p"
    fi
  done
}

cmd_uninstall() { cmd_stop; cmd_unlink; rm -rf "$STATE_DIR" "$CFG_DIR"; ok "removed"; }

usage() {
  cat <<'EOF'
zenreset.sh — clear OpenCode Zen rate limits by rotating egress IP

  install              deps + all engines
  doctor [--no-fetch]  install engines, probe sockets, boot-test each engine
  reset                rotate until clear, then launch opencode serve
  reset --bg           same, serve daemonised
  reset --engine NAME  force one engine
  serve                (re)start opencode serve through the proxy
  start | status | stop
  watch                poll Zen, auto-reset + auto-serve
  forget               clear the cached working engine
  shim                 opencode wrapper that auto-applies the proxy
  link                 install an `oc` shortcut on your PATH
  unlink               remove it

engines: usque (default), warp-plus-linux, warp-plus-android, cloudflare-warp
config : ~/.config/zenreset/config.env
EOF
}

# --------------------------------- dispatch ---------------------------------
CMD="${1:-help}"; shift || true
NO_SERVE=0; DOCTOR_FETCH=1
for a in "$@"; do
  case "$a" in
    --no-serve)  NO_SERVE=1 ;;
    --no-fetch)  DOCTOR_FETCH=0 ;;
    --bg)        SERVE_BACKGROUND=1 ;;
    --fg)        SERVE_BACKGROUND=0 ;;
    --engine=*)  ENGINE="${a#*=}" ;;
    --engine)    ENGINE="__next__" ;;
    *) if [ "$ENGINE" = "__next__" ]; then ENGINE="$a"; else warn "unknown flag: $a"; fi ;;
  esac
done
[ "$NO_SERVE" = "1" ] && SERVE_AUTOSTART=0

# help/version/status/stop/forget/unlink/uninstall must not create state directories.
case "$CMD" in
  install|doctor|start|reset|serve|watch|shim|link) ensure_dirs ;;
esac

case "$CMD" in
  install)   cmd_install ;;
  doctor)    cmd_doctor ;;
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  status)    cmd_status ;;
  reset)     cmd_reset ;;
  serve)     cmd_serve ;;
  watch)     cmd_watch ;;
  forget)    cmd_forget ;;
  shim)      cmd_shim ;;
  link)      cmd_link ;;
  unlink)    cmd_unlink ;;
  uninstall) cmd_uninstall ;;
  help)      usage ;;
  version)   echo "$VERSION" ;;
  *)         usage ;;
esac
