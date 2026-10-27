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
