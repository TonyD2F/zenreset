Checked GitHub before writing anything. The key finding that makes this solvable: **Zen's free-model limit is keyed to your egress IP, not your account.** opencode issue [#34344](https://github.com/anomalyco/opencode/issues/34344) states it outright — "Rate limits on free models are tied to IP address, connecting to a VPN when you hit a limit resets it immediately and your session stays."

So "resetting the limit" means exactly one thing: **change your egress IP and make opencode use it.** Nothing else in the CLI or config matters.

Two constraints that shape the script:

1. **No root, no TUN in proot.** So kernel WireGuard is out. Solution: [`bepass-org/warp-plus`](https://github.com/bepass-org/warp-plus) — a userspace WARP client that exposes a local SOCKS5 listener. It ships a static `linux-arm64` binary, runs fine inside proot, and deleting its `--cache-dir` forces a fresh WARP registration = fresh Cloudflare exit IP.
2. **Bun has no SOCKS5 support** and silently treats `socks5://` as HTTP (oven-sh/bun#16812). So you need a real HTTP proxy in front. privoxy from Debian's own repos does that.

Relevant repos I checked: `BerkeOruc/oplire` and `nxyystore/oplirex` (good, but they drive `warp-cli`, which is awkward on Termux), `Utsav-X-bit/opencode-ip-rotator` and `Sprtcrnbry/opencode-ip-rotator` (Docker-based — no Docker in proot), `shahradelahi/cloudflare-warp` (SOCKS+HTTP in one binary, decent alternative to warp-plus+privoxy), `bdliyq/opencode-rate-limit-retry` and `liamvinberg/opencode-rate-limit-fallback` (plugins — they retry/switch models but don't rotate IP).


### Setup

```bash
cd ~
cat > zenreset.sh   # paste, or: chmod +x zenreset.sh
chmod +x zenreset.sh
./zenreset.sh install
./zenreset.sh shim          # optional but recommended
```

Then, when you hit a 429:

```bash
./zenreset.sh reset
```

Or let it babysit itself:

```bash
nohup ./zenreset.sh watch &
```

### What it actually changes

| Layer | Action | Why |
|---|---|---|
| WARP identity | wipes `--cache-dir`, forces re-registration | new Cloudflare exit IP — this is the thing that lifts the limit |
| Exit IP | loops until the IP differs *and* Zen stops 429-ing | guards against landing on a shared IP that's already burned |
| Egress path | warp-plus SOCKS → privoxy → HTTP on `127.0.0.1:18118` | Bun can't speak SOCKS5 |
| opencode env | lowercase `http_proxy`/`https_proxy` | opencode ignores the uppercase ones ([#6953](https://github.com/anomalyco/opencode/issues/6953)) |
| opencode shim | wrapper in `~/.local/bin` sources the env | so you never have to remember exports |
| Local caches | clears `~/.cache/opencode` only | `auth.json` is preserved, so no re-login |

### Caveats worth knowing

- **The account quota still exists.** If your daily/hourly free quota is exhausted, no amount of IP rotation helps and every attempt will 429. The script's failure message says this explicitly rather than looping forever.
- **`EXIT_MODE=psiphon`** with `--country` gives you a genuinely different IP range, useful when WARP's shared pool is saturated. Set it in `~/.config/zenreset/config.env`.
- **warp-plus will log a TUN warning** inside proot — expected, it falls back to SOCKS mode.
- **If `zen_probe` returns `UNKNOWN`** it's usually the `FreeTierError` ("free tier can only be used from within OpenCode"), which means the UA check didn't match. Harmless — the real test is running opencode itself.
- If you'd rather not run privoxy, [`shahradelahi/cloudflare-warp`](https://github.com/shahradelahi/cloudflare-warp) exposes SOCKS5 *and* HTTP from one binary (`warp run --socks-addr ... --http-addr ...`), so you can swap both components for it.


It's for **Debian running inside proot on Android** — i.e. `proot-distro login debian` from Termux. That's the environment the script assumes and the only one it's tuned for.

Everything it touches lives inside that Debian container: `apt-get`, `/usr/local/bin`, `~/.config`, the WARP client, privoxy, and `opencode` itself. Nothing runs on the Termux side.

| Environment | Works? | Notes |
|---|---|---|
| Debian via proot-distro in Termux | Yes — target | `usque` default, EPERM handling, no-IPv6 handling all apply |
| Real Debian / Ubuntu / a VPS | Yes | Better, actually — see below |
| Termux natively (no proot) | No, not as-is | needs patching |

**Why not Termux directly:** the script uses Debian conventions Termux doesn't have — `apt-get` instead of `pkg`, `/usr/local/bin` instead of `$PREFIX/bin`, glibc paths instead of bionic. It would need those swapped, plus different release asset names (`android-arm64` rather than `linux-arm64`). Not hard, just not what's written.

**On real Debian it works better, not worse.** Two things are proot-specific problems:

- The `SO_RCVBUFFORCE`/`SO_SNDBUFFORCE` EPERM failure happens because proot's root is *fake* root with no `CAP_NET_ADMIN`. On real Debian as root you have that capability, so warp-plus doesn't crash and both warp-plus engines become usable.
- `/proc/net/if_inet6` missing is your proot kernel, not Debian itself.

So on a real Debian box you'd want to reorder to put warp-plus first:

```bash
# ~/.config/zenreset/config.env
ENGINES="warp-plus-linux warp-plus-android usque cloudflare-warp"
```

`usque` stays as the default purely because it's the only engine that survives the proot capability gap.

**One thing worth flagging:** `link` installs `oc` into `/usr/local/bin` *inside* the container. So `oc` works after `proot-distro login debian`, but not from a Termux prompt. If you want it from Termux too, add a Termux-side wrapper:

```bash
# in Termux, not proot
mkdir -p ~/.local/bin
printf '#!/data/data/com.termux/files/usr/bin/sh\nexec proot-distro login debian -- bash -lc "cd ~/Desktop/reset && ./zenreset.sh %s"\n' '"$@"' > ~/.local/bin/oc
chmod +x ~/.local/bin/oc
```

That gives you `oc reset` from Termux that drops into Debian, runs the reset, and returns. Note it can't be `oc` in both places at once — pick one, or name the Termux one `ocz`.
