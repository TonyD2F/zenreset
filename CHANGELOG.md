# Changelog

Notable changes to `zenreset.sh`. This project uses [semantic
versioning](https://semver.org/): the minor number moves for behaviour changes,
the patch number for fixes to a release.

## [1.7.0] - 2026-10-27

### Added

- `SERVE_PASSWORD` and `SERVE_CORS`. `serve` exports the password as
  `OPENCODE_SERVER_PASSWORD`, which turns on basic auth (username `opencode`),
  and passes each CORS origin as its own `--cors` flag. A phone can now serve to
  a PC browser on the same network without hand-writing those flags.
- `reset` prints a reminder to remove other OpenCode providers when limits
  persist; rotation only affects the IP that Zen sees.
- README: LAN/PC-browser recipe, `SERVE_PASSWORD`/`SERVE_CORS` reference, and a
  troubleshooting entry for limits that survive a successful reset.

## [1.6.0] - 2026-10-27

### Changed

- `serve` asks which IP and port to serve on. The current `SERVE_HOST` and
  `SERVE_PORT` are shown as defaults, so pressing Enter twice behaves exactly as
  before. The prompt is skipped when stdin is not a terminal, so scripts, CI,
  and `curl | bash` stay non-interactive.

### Fixed

- A non-numeric or out-of-range port typed at the prompt falls back to `4096`
  with a warning instead of being passed to `opencode serve`.

## [1.5.3] - 2026-10-27

### Changed

- `doctor` skips the `warp-plus-linux` and `warp-plus-android` boot tests when
  it detects proot, instead of waiting for both to fail. Both engines are known
  not to work under proot (`SO_RCVBUFFORCE` returns `EPERM`), so the test only
  cost about a minute. Detection uses `PROOT_L2S_DIR`, `PROOT_TMP_DIR`, or
  `container=proot-distro`.

### Added

- `CHANGELOG.md`, plus CI, release, license, and platform badges in the README.

## [1.5.2] - 2026-10-27

### Security

- The Zen API key is no longer passed on the `curl` command line, where it was
  visible to `ps` and `/proc`. It now travels in a `0600` header file that is
  removed afterwards.
- Engine downloads can be pinned with `SHA256_<ENGINE>` variables. A mismatch
  aborts the install; without a pin, the script warns that the asset is
  unverified.
- GitHub API failures are reported as what they are (rate limited, not found,
  unreachable) instead of "no matching asset". `GH_TOKEN` is used when present.

### Added

- `MAX_RESET_SECONDS` (default `900`) caps a full `reset`, so a stack of failing
  engines can no longer run for half an hour.
- `uninstall` asks for confirmation and refuses to delete state when it has no
  terminal unless `--yes` is passed.

### Fixed

- `watch` no longer starts `serve` against a dead proxy; it restarts the stack
  when either privoxy or the engine is down.
- ToS and quota note: rotation changes the IP, not the per-account quota.

## [1.5.1] - 2026-10-27

### Fixed

- `doctor` stopped leaving the engine and privoxy running when a boot test
  failed, and now cleans up on `INT`/`TERM`.
- `version` and `help` no longer create the state and config directories.
- Output is plain when stdout is not a TTY, or when `NO_COLOR` is set.

### Added

- A fast, offline test suite (`make test`) covering the three fixes above,
  wired into CI alongside `shellcheck`.

## [1.5.0] - 2026-10-27

### Added

- First release: rotate the WARP egress IP with `usque`, `warp-plus-linux`,
  `warp-plus-android`, or `cloudflare-warp`; bridge to HTTP via privoxy; probe
  OpenCode Zen; start `opencode serve`; manage the `oc` shortcut.
