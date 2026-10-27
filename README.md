# zenreset

Clear OpenCode Zen free-tier `Rate limit exceeded` errors by rotating your WARP egress IP.

**Platform:** Debian. Runs on a regular Debian host (`arm64`/`amd64`) and on
Debian running under [`proot-distro`](https://github.com/termux/proot-distro)
inside Termux on Android (`aarch64`).

## Why this exists

OpenCode Zen keys its free-model limiter to the caller's **egress IP**
([anomalyco/opencode#34344](https://github.com/anomalyco/opencode/issues/34344)).
Changing your WARP identity gives you a new exit IP, which clears the `429`
immediately, and your account session survives the change.

There is a second, **separate per-account daily/hourly quota** that IP rotation
cannot fix. `zenreset.sh` says so plainly when it exhausts its attempts, instead
of pretending another rotation will help.

The script is built for the awkward case this was written from: OpenCode running
on Debian installed through `proot-distro` under Termux on Android, where the
usual WireGuard-based engines fall over (see [Engines](#engines)). The same
script runs unchanged on a normal Debian host.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/TonyD2F/zenreset/main/zenreset.sh -o zenreset.sh
chmod +x zenreset.sh
./zenreset.sh version   # expect: 1.5.0
```

Every [release](https://github.com/TonyD2F/zenreset/releases) also carries
`zenreset.sh` as a download, if you would rather pin a version than track
`main`.

## Requirements

- **Primary target:** Debian via [`proot-distro`](https://github.com/termux/proot-distro)
  under Termux on Android, `aarch64`. This is the environment the script was
  designed and tested against.
- **Also works on:** an ordinary Debian host on `arm64` or `amd64`. The script
  picks the matching release asset from each engine's latest GitHub release and
  installs anything it is missing (`curl`, `unzip`, `privoxy`, `python3`) with
  `apt-get`.
- `opencode` on `PATH` if you want the automatic `opencode serve` step.
- An authenticated OpenCode install (`~/.local/share/opencode/auth.json`) if you
  want the Zen probe to report `OK` or `LIMITED` rather than `UNKNOWN`.
- Network access on first use: the script downloads third-party binaries at
  runtime. Nothing is vendored in this repository.

## Quick start

```bash
# 1. Inspect the environment, fetch the engines, probe sockets, boot-test them.
./zenreset.sh doctor

# 2. Rotate the egress IP until Zen answers, then start `opencode serve`.
./zenreset.sh reset

# 3. Optional: install an `oc` shortcut on your PATH.
./zenreset.sh link
oc status
```

`reset --bg` runs the same rotation with `opencode serve` daemonised instead of
in the foreground.

### The `oc` shortcut

`./zenreset.sh link` writes an `oc` wrapper to `/usr/local/bin` when that
directory is writable and already on `PATH`; otherwise it uses `~/.local/bin`
(and creates it). The wrapper forwards short aliases:

```text
oc            -> reset      oc r      -> reset
oc d          -> doctor     oc s      -> status
oc v          -> serve      oc w      -> watch
oc up         -> start      oc down   -> stop
oc f          -> forget     oc h      -> help
```

## Commands

All flags are parsed globally, so they may follow any subcommand.

| Command | What it does |
|---|---|
| `install` | Installs missing dependencies, fetches every engine, writes the privoxy config and proxy env file. |
| `doctor [--no-fetch]` | Prints arch, kernel, TUN, IPv6, privoxy, and cached engine. Fetches engines (unless `--no-fetch`), lists which are present, runs the socket-option probe, then boot-tests each installed engine. |
| `reset` | Rotates the WARP identity, checks the new egress IP, probes Zen, clears local OpenCode caches, then starts `opencode serve`. |
| `reset --bg` | Same as `reset`, but `opencode serve` is daemonised. |
| `reset --engine NAME` | Forces a single engine instead of walking the configured order. |
| `serve` | Brings the stack up if needed, then (re)starts `opencode serve` through the proxy. |
| `start` | Brings up the first engine that works, writes the proxy env, and prints status. |
| `status` | Shows engine, privoxy, and serve state, the direct IP, the proxy IP, and the Zen probe result. |
| `stop` | Stops `opencode serve`, privoxy, and the engine. |
| `watch` | Polls Zen every `WATCH_INTERVAL` seconds; resets on `LIMITED` and restarts `serve` if it is down. |
| `forget` | Deletes the cached working-engine file (`~/.config/zenreset/engine.working`). |
| `shim` | Wraps the real `opencode` binary in `~/.local/bin/opencode` so it always sources the proxy env. |
| `link` | Installs the `oc` shortcut described above. |
| `unlink` | Removes the `oc` shortcut from `/usr/local/bin` and `~/.local/bin`. |
| `uninstall` | Stops everything, removes the shortcut, and deletes the state and config directories. |
| `help` | Prints the usage block. |
| `version` | Prints the version (`1.5.0`). |

| Flag | Effect |
|---|---|
| `--no-serve` | Sets `SERVE_AUTOSTART=0` for this run; rotation finishes without starting `opencode serve`. |
| `--bg` | Sets `SERVE_BACKGROUND=1`; `opencode serve` runs daemonised. |
| `--fg` | Sets `SERVE_BACKGROUND=0`; `opencode serve` runs in the foreground. |
| `--engine NAME` | Sets `ENGINE` to one engine for this run (`--engine=NAME` also works). |
| `--no-fetch` | Sets `DOCTOR_FETCH=0`; `doctor` skips downloading engines. |

## Engines

Default order: `usque`, `warp-plus-linux`, `warp-plus-android`, `cloudflare-warp`.
`engine_order()` moves whichever engine last worked, cached in
`~/.config/zenreset/engine.working`, to the front. `forget` clears that cache.

| Engine | Protocol | Status on proot | Notes |
|---|---|---|---|
| `usque` | MASQUE/QUIC | **Works — default** | Never touches the `wireguard-go` bind path, so the proot limitation below does not apply. Registers a WARP account on first use. |
| `warp-plus-linux` | WireGuard (`wireguard-go`) | **Fails under proot** | `SO_RCVBUFFORCE` / `SO_SNDBUFFORCE` return `EPERM`; the vendored bind code does not fall back to plain `SO_RCVBUF`, the device tears down and nil-derefs. |
| `warp-plus-android` | WireGuard (`wireguard-go`) | **Fails under proot** | Same vendored `wireguard-go` code path as the Linux build; both builds are affected. |
| `cloudflare-warp` | Cloudflare WARP client | Not the default | Kept as a fallback option. `doctor` boot-tests it. It talks directly to its own SOCKS/HTTP listeners, so no privoxy bridge is used. |

### Why the warp-plus builds fail under proot

Under proot you are fake root without `CAP_NET_ADMIN`, so
`SO_RCVBUFFORCE` and `SO_SNDBUFFORCE` return `EPERM`. warp-plus's vendored
`wireguard-go` does not fall back to plain `SO_RCVBUF`, so the device tears down
and nil-derefs at:

```text
RoutineTUNEventReader -> Up -> BindUpdate -> Open -> listenNet
wireguard/conn/bind_std.go
```

Both the Linux and Android builds are affected. This was confirmed empirically
with `doctor`'s socket probe. `usque` is MASQUE/QUIC and never touches that code
path, so it is unaffected — which is why it is the default.

### The SOCKS-to-HTTP bridge

Bun, OpenCode's runtime, has no SOCKS5 support and silently treats
`socks5://` as HTTP. The warp-plus engines expose SOCKS, so the script bridges
that listener to a real HTTP proxy with **privoxy**. `usque` also goes through
the same HTTP port used by the probe and by OpenCode.

## Configuration

The script reads `~/.config/zenreset/config.env` (or
`$XDG_CONFIG_HOME/zenreset/config.env`) after applying its built-in defaults.
The file is sourced as shell. `config.env.example` in this repository mirrors
every tunable and default.

| Variable | Type | Default | Effect |
|---|---|---|---|
| `SOCKS_PORT` | port | `18086` | Local SOCKS5 port the engines listen on. |
| `HTTP_PORT` | port | `18118` | Local HTTP proxy port used by privoxy, the IP check, the Zen probe, and OpenCode. |
| `MAX_ATTEMPTS` | integer | `6` | Rotations attempted per engine before moving on. |
| `ATTEMPT_SLEEP` | seconds | `3` | Pause between attempts. |
| `ENGINES` | list | `usque warp-plus-linux warp-plus-android cloudflare-warp` | Engine order used when `ENGINE` is empty. |
| `ENGINE` | string | empty | Force one engine; empty means walk `ENGINES`/the cached order. |
| `EXIT_MODE` | `warp` \| `psiphon` \| `scan` | `warp` | warp-plus exit strategy. `psiphon` adds `--cfon --country $PSIPHON_COUNTRY`; `scan` adds `--scan`. Ignored by `usque` and `cloudflare-warp`. |
| `PSIPHON_COUNTRY` | country code | `US` | Country passed to warp-plus when `EXIT_MODE=psiphon`. |
| `WARP_EXTRA_ARGS` | string | `-4` | Extra arguments appended to warp-plus invocations (IPv4-only by default). |
| `WARP_TUN` | `0` \| `1` | `0` | `1` adds `--tun-experimental` to warp-plus. |
| `PROBE_ZEN` | `0` \| `1` | `1` | Probe Zen after each new IP. With `0`, the first new IP is accepted without a probe. |
| `PROBE_MODEL` | model ID | `deepseek-v4.1-flash-free` | Model sent in the probe request. |
| `CLEAR_CACHE` | `0` \| `1` | `1` | Delete `~/.cache/opencode` after a successful rotation. |
| `WATCH_INTERVAL` | seconds | `60` | Poll interval for `watch`. |
| `FORCE_NEW_IP` | `0` \| `1` | `1` | Require the egress IP to differ from the previous one before accepting it. |
| `ENGINE_BOOT_WAIT` | seconds | `6` | Grace period before an engine is considered alive or dead. |
| `PROXY_WAIT` | seconds | `30` | How long to wait for an engine to provide working egress. |
| `SERVE_AUTOSTART` | `0` \| `1` | `1` | Start `opencode serve` after a successful rotation. `--no-serve` overrides this. |
| `SERVE_BACKGROUND` | `0` \| `1` | `0` | Run `opencode serve` daemonised. `--bg` / `--fg` override this. |
| `SERVE_HOST` | address | `127.0.0.1` | `--hostname` passed to `opencode serve`. |
| `SERVE_PORT` | port | `4096` | `--port` passed to `opencode serve`. |
| `SERVE_ARGS` | string | empty | Extra arguments appended to `opencode serve`. |
| `SERVE_WAIT` | seconds | `3` | Wait after launching a background `serve` before checking it. |
| `SERVE_RESTART_ON_RESET` | `0` \| `1` | `1` | Restart an already-running `serve` after a reset. |

## How it works

1. **Rotate the WARP identity.** `reset` stops the engine, deletes its per-engine
   state directory, and starts it again with the same engine binary.
2. **Get a new egress IP.** The new WARP identity produces a new exit IP.
3. **Bridge SOCKS to HTTP.** For the SOCKS-based engines, privoxy listens on
   `HTTP_PORT` and forwards to the engine's SOCKS listener.
4. **Export lowercase proxy variables.** `proxy.env` sets `http_proxy` and
   `https_proxy` — OpenCode ignores the uppercase forms
   ([anomalyco/opencode#6953](https://github.com/anomalyco/opencode/issues/6953)).
5. **Verify the new IP.** The script reads
   `https://www.cloudflare.com/cdn-cgi/trace` through the proxy and compares it
   with the previous IP (unless `FORCE_NEW_IP=0`).
6. **Probe Zen.** It sends a tiny chat completion to the Zen endpoint with the
   key from `auth.json` and classifies the result as `OK`, `LIMITED`, or
   `UNKNOWN`.
7. **Clear caches.** On success — or an inconclusive probe, which is treated as
   success — it removes `~/.cache/opencode` when `CLEAR_CACHE=1`.
8. **Start `opencode serve`.** With `SERVE_AUTOSTART=1`, `serve` is started
   (foreground by default, background with `--bg`).

If every attempt on every engine is still `LIMITED`, the script stops and warns
that you are probably on the per-account quota rather than the IP limiter.

## Troubleshooting

**`bind_std.go` panic / `panic:` in the engine log**

You are running a warp-plus build under proot. `SO_RCVBUFFORCE` and
`SO_SNDBUFFORCE` return `EPERM` because proot has no `CAP_NET_ADMIN`, and the
vendored `wireguard-go` bind code does not fall back. The panic path is
`RoutineTUNEventReader -> Up -> BindUpdate -> Open -> listenNet`. Use `usque`
(the default) instead; `./zenreset.sh reset --engine usque` forces it.

**`proxy did not come up in time` / `no egress IP`**

The engine is alive but traffic is not flowing. Check the per-engine log in
`~/.local/share/zenreset/log/engine-<engine>.log`. `doctor` boot-tests every
installed engine and shows which one survives. A missing `/dev/net/tun` or
missing IPv6 can also prevent an engine from working.

**`still limited` on every fresh IP**

This is the separate per-account daily/hourly quota, not the egress-IP limiter.
IP rotation cannot fix it. Wait for the quota window to reset; the script prints
this warning when it exhausts all engines and attempts.

**`cloudflare-warp: no linux-<arch> asset matched`**

The release does not contain an asset matching the current architecture. The
script prints the release's actual asset names after the warning — `doctor`
prints them too — so you can compare them with `uname -m`. `arm64`, `amd64`,
and `armv7` are the recognized tags.

**`bash: unexpected EOF while looking for matching '"'` when copy-pasting**

The pasted script was truncated or a smart quote replaced a plain `"`.
Re-download it with the `curl` command above, then run:

```bash
bash -n zenreset.sh
```

A clean file ends with `esac`. Smart quotes (`“ ” ‘ ’`) are not valid shell
syntax; replace them with plain ASCII quotes.

## Uninstall

```bash
./zenreset.sh uninstall
```

This stops `opencode serve`, privoxy, and the engine, removes the `oc` shortcut,
and deletes:

- the state directory: `~/.local/share/zenreset` (or `$XDG_DATA_HOME/zenreset`)
- the config directory: `~/.config/zenreset` (or `$XDG_CONFIG_HOME/zenreset`)

It leaves behind:

- packages installed by `ensure_deps` (`curl`, `unzip`, `privoxy`, `python3`)
- `opencode` itself, and the `~/.local/bin/opencode` shim if you ran `shim`
- `zenreset.sh` and this repository

Remove the shim manually with `rm ~/.local/bin/opencode` if you created it.

## Credits

- [bepass-org/warp-plus](https://github.com/bepass-org/warp-plus) — the
  WireGuard-based WARP client (Linux and Android builds).
- [Diniboy1123/usque](https://github.com/Diniboy1123/usque) — the MASQUE/QUIC
  WARP client that works under proot, and the default engine.
- [shahradelahi/cloudflare-warp](https://github.com/shahradelahi/cloudflare-warp)
  — the third engine option.
- [Privoxy](https://www.privoxy.org/) — the SOCKS-to-HTTP bridge.
- [anomalyco/opencode#34344](https://github.com/anomalyco/opencode/issues/34344)
  — the report that identified IP-keyed Zen rate limiting.

## License

MIT. See [LICENSE](LICENSE).
