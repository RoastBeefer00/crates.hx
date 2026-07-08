# crates.hx

crates.io version hints for `Cargo.toml` files in [helix-steel](https://github.com/mattwparas/helix).

When you open a `Cargo.toml`, each dependency line gets an inline annotation showing the latest version from crates.io — green `✓` if your major version matches, yellow `⚠` if a newer major is available.

![crates.hx demo](demo/crates.gif)

## Requirements

- [mattwparas/helix](https://github.com/mattwparas/helix) (the Steel-enabled fork)
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
(enable-crates-auto!)   ; auto-run on every Cargo.toml open
```

## Usage

| Command | Description |
|---|---|
| `:crates-show-hints` | Fetch and display version hints for the current `Cargo.toml` |
| `:crates-clear-hints` | Remove hints from the current buffer |

With `(enable-crates-auto!)` called at startup, hints load automatically whenever you open a `Cargo.toml` — no manual command needed.

## How it works

1. On `document-opened`, checks if the file path ends in `Cargo.toml`
2. Parses `[dependencies]`, `[dev-dependencies]`, and `[build-dependencies]` sections
3. Spawns a background thread — one `curl` call per crate to `crates.io/api/v1/crates/{name}`
4. Re-enters the editor context and calls `add-inlay-hint` at the end of each dep line

Version status is based on major version: `"1.0"` against `1.0.219` is `✓`; against `2.0.0` is `⚠`.

Supports both inline string (`serde = "1.0"`) and table (`tokio = { version = "1", features = [...] }`) forms. Path and git dependencies (no `version` field) are skipped.
