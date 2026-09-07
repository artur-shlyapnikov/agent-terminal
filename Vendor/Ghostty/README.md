# Vendored libghostty

Pinned build of Ghostty's embeddable library ("libghostty-internal", packaged
as `GhosttyKit.xcframework`) for AgentTerminal. Built unmodified from upstream;
see `commit.txt` for the exact pin and `patches.md` for local patches
(currently none).

## What is vendored

| Path | Contents |
|---|---|
| `commit.txt` | Pinned upstream commit SHA (tracked) |
| `README.md`, `patches.md` | This doc; patch ledger (tracked) |
| `build/GhosttyKit.xcframework/` | XCFramework, slice `macos-arm64` (gitignored) |
| `build/lib/libghostty-internal.a` | Static library, arm64, ~129 MB ReleaseFast (gitignored) |
| `build/include/ghostty.h` | Embedder C API header, extracted for direct discovery (gitignored) |
| `build/include/module.modulemap` | Clang module map for Swift imports (gitignored) |

The API is the internal embedder surface (`include/ghostty.h`, "libghostty-internal")
tailored to Ghostty's own macOS app — not a stable external SDK. Upstream now
also ships a documented external alternative (`include/ghostty/vt.h`,
"libghostty-vt"), which does NOT provide the native-view/AppKit integration,
PTY process ownership, or the point/screen text reads we rely on. Per the
architecture doc we deliberately pin and isolate the internal API behind our
own bridge; treat every upgrade as a breaking-change review.

## Pin

- Commit: `da5ddcb0857c0e4ddb32f7a089911e9038d040f3`
  (`main`, 2026-08-22, version 1.3.2-dev). Builds clean on this commit — no
  fallback was needed.
- Zig: `0.16.0` (exactly `minimum_zig_version` from that commit's
  `build.zig.zon`).
- Build invocation (run by the script):

  ```sh
  zig build -Doptimize=ReleaseFast -Dapp-runtime=none \
            -Demit-xcframework=true -Dxcframework-target=native \
            -Demit-macos-app=false
  ```

## Rebuilding

```sh
Scripts/build-ghostty-xcframework.sh
```

The script is idempotent: it re-checks out the pin in a cached clone at
`~/Library/Caches/agentterminal/ghostty` (never inside this repo), bootstraps
the exact zig tarball from ziglang.org if missing, builds, and refreshes
`Vendor/Ghostty/build/`. Environment overrides: `GHOSTTY_SRC_DIR`,
`GHOSTTY_TOOLS_DIR`, `GHOSTTY_OPTIMIZE` (default `ReleaseFast`),
`GHOSTTY_UPSTREAM_URL`. Full Xcode is required (`xcodebuild -create-xcframework`);
the script sets `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
when needed.

## Zig toolchain provenance

Downloaded from the official `https://ziglang.org/download/<ver>/zig-aarch64-macos-<ver>.tar.xz`
into `~/.local/share/agentterminal-tools/zig-<ver>/`. Brew is deliberately not
used so the version always matches the pin's `minimum_zig_version` byte-for-byte.

## Updating the pin

1. Pick the upstream commit (usually `origin/main` HEAD):
   `git -C ~/Library/Caches/agentterminal/ghostty fetch origin && git -C ~/Library/Caches/agentterminal/ghostty rev-parse origin/main`
2. Write the full 40-hex SHA into `Vendor/Ghostty/commit.txt`
   (optionally with a trailing `# comment`; only the first field is read).
3. Run `Scripts/build-ghostty-xcframework.sh`. If it fails because the new
   commit needs a different zig or has a broken build, either fix forward or
   move to the nearest earlier building commit and record BOTH SHAs:
   the working pin first, then `<broken-sha> # fallback reason` on a following
   line. Document the failure in this README.
4. Re-run the header review (surface config fields, callbacks, screen-read
   APIs — see below) and update the architecture doc if anything moved.
5. Note: upstream's `include/ghostty.h` may gain/lose APIs without notice;
   the pin exists precisely to make that an explicit decision.

## Key embedding-API facts (verified against this pin's header)

- **Surface config** (`ghostty_surface_config_s`, via `ghostty_surface_config_new()`):
  `platform.macos.nsview` (native view handoff), `working_directory`, `command`,
  `env_vars[]` + `env_var_count`, `initial_input`, `wait_after_command`,
  `context` (window/tab/split), `userdata`, `scale_factor`, `font_size`.
- **App/runtime**: `ghostty_app_new(const ghostty_runtime_config_s*)`;
  runtime config carries `wakeup_cb`, `action_cb` (typed
  `ghostty_action_s` stream incl. `child_exited {exit_code}`,
  `command_finished {exit_code, duration_ns}`, pwd, title, bell),
  clipboard callbacks, `close_surface_cb`. Drive with `ghostty_app_tick`.
- **Process exit**: event `GHOSTTY_ACTION_SHOW_CHILD_EXITED` /
  `child_exited` union member plus polling `ghostty_surface_process_exited()`
  and `ghostty_surface_foreground_pid()`.
- **Focus/input**: `ghostty_app_set_focus`, `ghostty_surface_set_focus`,
  `ghostty_surface_key/text/preedit/mouse_*`.
- **Screen reading** — the critical piece: text extraction takes a
  `ghostty_selection_s { top_left, bottom_right, rectangle }` where each
  endpoint is a `ghostty_point_s { tag, coord, x, y }` with tag
  `GHOSTTY_POINT_ACTIVE | VIEWPORT | SCREEN | SURFACE` and coord
  `EXACT | TOP_LEFT | BOTTOM_RIGHT`. So lifecycle detection can read
  `GHOSTTY_POINT_SCREEN` coordinates (full scrollback-backed screen space),
  independent of what the user has scrolled into the viewport — exactly the
  "read the live screen, not the viewport" semantics required by the
  architecture. Entry points:
  `bool ghostty_surface_read_text(ghostty_surface_t, ghostty_selection_s, ghostty_text_s*)`
  and `void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*)`
  (`ghostty_text_s` carries pixel origin, UTF-8 bytes, offsets). There are no
  separate per-point read functions; everything goes through selection-shaped
  reads.
- **Threading**: the header documents NO thread requirements for
  `ghostty_surface_free` (it has no doc comment). Implementation evidence
  (`src/apprt/embedded.zig`): it synchronously runs `Surface.deinit()`, which
  joins the renderer and IO threads. Treat it as main-thread-affine like
  creation (upstream's macOS app creates/frees surfaces on the main thread);
  our bridge must enforce that itself.
