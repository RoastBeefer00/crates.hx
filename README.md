# crates.hx

crates.io version hints for `Cargo.toml` files in [helix-steel](https://github.com/mattwparas/helix).

When you open a `Cargo.toml`, each dependency line gets an inline annotation showing the latest version from crates.io — green `✓` if you're on the latest, red `⚠` if a newer version is available (behind by major, minor, or patch).

Colors come from universal theme scopes (`diff.plus` / `diff.minus`), so they work on any theme out of the box with no custom scope configuration.

![crates.hx demo](demo/crates.gif)

## Requirements

- [mattwparas/helix](https://github.com/mattwparas/helix) (the Steel-enabled fork), built with the `add-scoped-inlay-hint` binding
- `curl` on `$PATH`

## Installation

Add to your `cog.scm`:

```scheme
(#:name crates.hx #:git-url "https://github.com/RoastBeefer00/crates.hx.git")
```

Then run `forge install`.

In your `init.scm`:

```scheme
(require "crates.hx/crates.scm")
(enable-crates-auto!)   ; auto-run on Cargo.toml open and save

;; Optional: turn off the on-save refresh (open refresh stays on)
;; (set-crates-refresh-on-save! #f)
```

## Usage

| Command | Description |
|---|---|
| `:crates-show-hints` | Fetch and display version hints for the current `Cargo.toml` |
| `:crates-clear-hints` | Remove hints from the current buffer |

With `(enable-crates-auto!)` called at startup, hints load automatically whenever you open **or save** a `Cargo.toml` — no manual command needed.

### Configuration

| Function | Description |
|---|---|
| `(set-crates-refresh-on-save! #t/#f)` | Enable/disable re-fetching hints when a `Cargo.toml` is saved. Default `#t`. Open-refresh is always on. |

## How it works

1. On `document-opened` / `document-saved`, checks if the file path ends in `Cargo.toml`
2. Parses `[dependencies]`, `[dev-dependencies]`, `[build-dependencies]`, and `[workspace.dependencies]` sections
3. Spawns a background thread — one `curl` call per crate to `crates.io/api/v1/crates/{name}`
4. Re-enters the editor context and calls `add-scoped-inlay-hint` at the end of each dep line, tagging it with a theme scope (`diff.plus` / `diff.minus`) so the color follows the active theme

Version status compares the full semver: any component behind the latest (major, minor, or patch) is `⚠` outdated; only the newest is `✓`. For example `"1.2"` against `1.5.0` is `⚠`; `"1.5"` against `1.5.0` is `✓`.

Supports both inline string (`serde = "1.0"`) and table (`tokio = { version = "1", features = [...] }`) forms. Path and git dependencies (no `version` field) are skipped.
