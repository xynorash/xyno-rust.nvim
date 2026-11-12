# xyno-rust.nvim

Rust project plumbing for Neovim: a per-project Cargo context, a targets picker, an HTTP route picker, navigation helpers, language-server restart handling and a readiness indicator for the statusline.

I use this in my own Rust setup, [xynovim](https://github.com/xynorash/xynovim), and pulled it out as a standalone plugin. It is also the shared base of my other `xyno-*` Rust plugins, which require its modules (`xyno_rust.rust_context`, `xyno_rust.crate_meta`, `xyno_rust.code_actions`, ...).

The Cargo context and the tools picker are inspired by the Cargo tool window of the JetBrains IDEs. I still use JetBrains tools; this plugin is my own independent project and is not affiliated with JetBrains.

## Why

rust-analyzer and bacon-ls (clippy) are two servers that each run cargo. If they disagree on features or target, mutually exclusive features give bogus errors from one of them. This keeps one choice per workspace and applies it to both. The rest is the small glue I kept rewriting around it: run a target, find the route handlers of a web service, restart a server that died, see in the statusline whether the servers are ready.

## Requirements

- Neovim 0.12+
- `cargo` in `$PATH`
- rust-analyzer started through `vim.lsp` (I use [rustaceanvim](https://github.com/mrcjkb/rustaceanvim)) for the navigation helpers, code actions and the live part of the context
- the tree-sitter `rust` parser for `:RustRoutes` and the navigation helpers, the `yaml` parser for `:ActJob`
- [snacks.nvim](https://github.com/folke/snacks.nvim) (picker and terminal) for `:RustContext`, `:RustTargets`, `:RustTools` and `:RustRoutes`. It is not required to load the plugin: without it those commands print one error line and nothing else happens.
- optional tools, only for the entries that call them: `rustup`, `samply`, `cargo-flamegraph`, `cargo-bloat`, `cargo-machete`, `cargo-deny`, `cargo-audit`, `cargo-llvm-cov`, `act`, `curl`, bacon-ls

No other plugin is required. The profile entries of `:RustTargets` build with `--profile profiling`, which you define yourself (for example `[profile.profiling]` with `inherits = "release"` and `debug = true` in `~/.cargo/config.toml`).

## Install (lazy.nvim)

```lua
{
  "xynorash/xyno-rust.nvim",
  dependencies = { "folke/snacks.nvim" }, -- pickers and terminals
  ft = "rust",
  cmd = { "RustContext", "RustTargets", "RustTools", "RustRoutes", "RustNew", "RustRestart", "RustTrust", "ActJob" },
  opts = {},
  keys = {
    { "<leader>rF", "<cmd>RustContext<cr>", ft = "rust", desc = "Cargo features / target" },
    { "<leader>rX", "<cmd>RustTargets<cr>", ft = "rust", desc = "Cargo targets: run / test / bench" },
    { "<leader>rZ", "<cmd>RustTools<cr>", ft = "rust", desc = "Cargo tools" },
    { "<leader>rN", "<cmd>RustRoutes<cr>", ft = "rust", desc = "HTTP routes" },
    { "<leader>ru", function() require("xyno_rust.rust_nav").goto_super() end, ft = "rust", desc = "Go to super method" },
    { "<leader>rl", function() require("xyno_rust.rust_nav").local_usages() end, ft = "rust", desc = "Usages in file (R/W)" },
    { "<leader>tD", function() require("xyno_rust.rust_tasks").doctests() end, ft = "rust", desc = "Doctests" },
  },
}
```

Load it when you open Rust (`ft`) or run one of its commands (`cmd`): the server-restart handling and the statusline component start with `setup()`. If you want a crashed server restarted in every session, load it with `event = "VeryLazy"` instead.

## Options

`require("xyno_rust").setup(opts)`; the defaults:

```lua
{
  commands = true, -- :RustContext :RustTargets :RustTools :ActJob :RustNew :RustRoutes :RustRestart :RustTrust
  keymaps = false, -- false | true | { context = lhs, targets = lhs, ... }
  modules = {
    context = true, -- xyno_rust.rust_context
    tasks = true,   -- xyno_rust.rust_tasks
    routes = true,  -- xyno_rust.rust_routes
    status = true,  -- xyno_rust.lsp_status (autocommands)
    restart = true, -- xyno_rust.rust_restart (autocommands)
    trust = true,   -- xyno_rust.trust (only defines :RustTrust; the trust API works without it)
  },
}
```

No global keymap is set by default. `keymaps = true` maps these, buffer-local in Rust files: `<leader>rF` context, `rX` targets, `rZ` tools, `rN` routes, `ru` go to super method, `rl` usages in file, `<leader>tD` doctests. A table maps only the actions you list, to the keys you choose (`false` skips one).

## Commands

| Command | What it does |
| --- | --- |
| `:RustContext` | Pick Cargo features (multi-select with `<Tab>`), then a target; applies it to the running rust-analyzer and bacon-ls and stores it for the workspace. |
| `:RustContext show` / `reset` | Print the context of this workspace / forget the stored choice. |
| `:RustTargets` | Pick a target of the workspace (bin, example, test, bench, lib) and run, test, build, bench or profile it in a bottom terminal. |
| `:RustTools` | Pick a workspace tool: timings, bloat, machete, deny, audit, duplicate versions, coverage summary. |
| `:RustRoutes` | Pick an axum / actix / rocket route and jump to it. |
| `:RustNew [name]` | `cargo new` (bin or lib) in the current directory and open it. |
| `:ActJob` | Run the GitHub Actions job under the cursor with `act`. |
| `:RustRestart` | Restart rust-analyzer and bacon-ls, also when one has died. |
| `:RustTrust [list \| add [dir] \| revoke [dir] \| revoke-all \| status [dir]]` | Workspaces you allowed to run code (see Workspace trust). The bare command lists them and revokes the one you pick. |
| `:checkhealth xyno-rust` | Versions, tools, the state files (invalid stored values are flagged), trust of the current workspace, how long `cargo metadata` takes there. |

## Lua API

Every module can be required on its own. `:help xyno-rust-api` has the signatures.

| Module | Public functions |
| --- | --- |
| `xyno_rust` | `setup(opts)`, `defaults`, `default_keymaps`, `api_version`, `version`, `compatible(want)` |
| `xyno_rust.cargo` | `metadata_async(root, cb, opts?)`, `metadata(root, opts?)`, `locate_async`, `locate`, `installed_targets_async(cb)`, `exec(argv, opts, cb)`, `invalidate(root?)`, `reset_caches()`, `pending()`, `config` |
| `xyno_rust.trust` | `is_trusted(root)`, `require(root, what, cb)`, `ask`, `trust(root, opts?)`, `revoke(root)`, `revoke_all()`, `list()`, `ra_overrides(root)`, `normalize(path)`, `file()` |
| `xyno_rust.fsutil` | `rename(tmp, dest)`, `slash(path)` |
| `xyno_rust.rust_context` | `root(path?, opts?)`, `root_async(path, cb)`, `warm()`, `get(root)`, `apply(root, ctx?)`, `pick()`, `reset()`, `describe(ctx?)`, `ra_cargo(ctx?)`, `cargo_flags(ctx?)`, `bacon_args(ctx?)`, `canon(path)`, `valid_feature(name)`, `valid_target(triple)`, `sanitize(ctx)` |
| `xyno_rust.rust_tasks` | `targets()`, `tools()`, `new(name?)`, `act_job()`, `doctests()`, `samply_cmd(build, bin)`, `target_items(root, meta)` |
| `xyno_rust.rust_routes` | `scan_source(src)`, `collect(root)`, `collect_async(root, cb)`, `clear_cache(root?)`, `pending()`, `pick()`, `config` |
| `xyno_rust.rust_nav` | `goto_super()`, `local_usages()` |
| `xyno_rust.lsp_status` | `component()`, `rust_analyzer(buf?)`, `bacon(buf?)`, `deps(buf?)`, `bacon_failed(id)`, `deps_begin(root, buf?)`, `deps_clear(root?)` |
| `xyno_rust.rust_restart` | `on_exit(name)`, `restart()`, `sweep()`, `check_shadow()`, `manifest_saved(file, buf?)`, `server_pids()`, `kill_survivors(pids, ms?)`, `kill_uninitialised()`, `resume_servers()` |
| `xyno_rust.code_actions` | `request`, `request_wait`, `wait_for`, `filter`, `apply`, `apply_async`, `apply_all`, `resolve_async`, `clients`, `client_name` |
| `xyno_rust.crate_meta` | `metadata`, `metadata_async`, `invalidate`, `normalize`, `dependencies`, `member_of`, `root`, `registry_dir`, `source_dir`, `read_manifest`, `read_lib`, `parse_features`, `info`, `info_async`, `search`, `search_async`, `index_path`, `parse_index`, `valid_name`, `valid_version`, `compare_versions`, `is_known_path_head`, `exec`, `config`, `std_crates` |
| `xyno_rust.deps` | `snacks()` |

A context is `{ all = boolean, no_default = boolean, features = string[], target = string? }`; nothing stored means all features and the host target. It lives in `stdpath("state")/rust-context.json`, keyed by workspace root. The buffer variable `vim.b.xyno_rust_stopped` (`{ [server] = true }`) marks the buffers of a server that exited.

## Nothing waits on a process

`cargo metadata` (up to 30 s), `cargo locate-project` (up to 5 s), `rustup target list` (up to 10 s) and the scan of every `.rs` file for routes used to run on the main thread. They no longer do (`xyno_rust.cargo`, `xyno_rust.rust_routes`):

- each query is a `vim.system` call with a callback and a timeout; the process is killed when the timeout passes, even if a wrapper such as the rustup proxy left the real cargo holding the pipes
- answers are cached: metadata until a `Cargo.toml` of the workspace or `Cargo.lock` changes, the workspace root per directory and manifest mtimes, installed targets for 60 s
- a request for something already being asked joins the running request (ten pickers, one `cargo` process)
- the route scan walks and parses in slices of at most `rust_routes.config.slice_ms` (8 ms) and gives the event loop back in between; the treesitter query is compiled once, and a rescan parses only the files whose size or mtime changed. Sources over `max_file_bytes` (1 MiB) are skipped.
- `:RustContext`, `:RustTargets`, `:RustTools`, `:RustRoutes`, `:RustNew` and the doctests mapping return at once and open their picker when the answer is there. `:RustRoutes` says "scanning routes ..." only when a scan takes more than 0.4 s.

The synchronous forms that stay exist because other plugins call them and cannot take a callback: `rust_context.root(path)` (used by xyno-new, xyno-crates, xyno-macros and `crate_meta`), `cargo.metadata()`, `cargo.locate()` and `rust_routes.collect()`. `root()` answers from the cache; only the first call for a directory waits for cargo, for at most `cargo.config.wait_ms` (2 s), and then returns the answer of the file-system walk (the late cargo answer still fills the cache). `root(path, { nowait = true })` never waits. The plugin asks cargo about every Rust buffer you enter (`rust_context.warm()`), so that first call is normally already answered. Calling `root()` for a directory cargo has never been asked about, on a slow cargo, is still a wait of up to 2 s; use `root_async` if you can.

`crate_meta` (the crates.io and `cargo metadata` client used by xyno-imports, xyno-crates and xyno-macros) already had asynchronous variants and is unchanged except for the trust handling below.

## Workspace trust

Running a target, a test, a bench, a doctest, `samply`, `cargo flamegraph`, any `:RustTools` entry or `:ActJob` executes code that comes with the project (build.rs, proc macros, tests, workflow steps). In a workspace you did not trust, the plugin asks first, once per workspace root:

- Trust this workspace / Trust everything under `<parent>` / Run this once / Do not run
- "Trust" is remembered in `stdpath("state")/xyno-rust-trust.json` (shared by all Neovim instances, written under a lock); "run once" and "do not run" remember nothing
- `:RustTrust` lists, adds and revokes entries; `:checkhealth xyno-rust` shows them and whether the current workspace is trusted
- the entry is the workspace root as reported by cargo, with symlinks resolved; a sibling directory with the same prefix is not covered, and a path *below* a trusted root is not either (only an "everything under" entry covers what is below it)

What does not need trust: reading `cargo metadata --no-deps` and `cargo locate-project` (what the pickers and the root lookup use). Checked with a workspace that has a `build.rs` and a `.cargo/config.toml` setting `rustc`, `rustc-wrapper` and `rustc-workspace-wrapper` to a logging script: neither command ran any of them, while `cargo check` on the same workspace did (the control in `tests/trust_spec.lua`).

A resolving `cargo metadata` (without `--no-deps`, which `xyno_rust.crate_meta` needs for the dependency graph) does run the configured rustc wrapper; the same check showed it. So in a workspace that is not trusted `crate_meta` overrides those settings through the environment (`RUSTC`, `RUSTC_WRAPPER`, `RUSTC_WORKSPACE_WRAPPER`) and does not retry online after the offline run failed (the error says `:RustTrust add`). If you rely on xyno-crates / xyno-imports / xyno-macros needing the network in a project, trust it once.

Other plugins use the same store:

```lua
local trust = require("xyno_rust.trust")
trust.is_trusted(root)                       -- boolean
trust.require(root, "cargo run", function(ok) -- asks once if needed; may call back before it returns
  if ok then ... end
end)
trust.ra_overrides(root)                     -- rust-analyzer settings without build scripts / proc macros ({} if trusted)
```

Limits: the plugin does not start rust-analyzer or bacon-ls, so it cannot stop them from running build scripts and proc macros in an untrusted workspace; `ra_overrides(root)` gives the settings to merge into your server config, and nothing applies it for you (xynovim's `lua/config/workspace_trust.lua` is one such config: it merges them, adds `checkOnSave = false`, does not start clippy, restarts the servers when `trust.trust` / `trust.revoke` run, and shows `RESTRICTED` through `lsp_status.add_part(fn)`, where `fn(bufnr)` returns a string added in front of the server states). There is no enterprise-style policy, no per-action allow list and no restricted-mode UI. When Neovim has no UI to ask (headless), the answer is "do not run".

## Compatibility contract

`require("xyno_rust").api_version` is `"major.minor"` (now `"1.1"`; `version` is the plugin release). The major number changes when a function the other xyno plugins call is removed or changes meaning, the minor number when functions are added. A dependent checks it once:

```lua
local ok, why = require("xyno_rust").compatible("1.1")
if not ok then vim.notify(why, vim.log.levels.ERROR) end
```

`tests/api_spec.lua` keeps a list of the functions xyno-new, xyno-imports, xyno-crates and xyno-macros call. The specs of those four plugins pass against this version (see Tests).

## Hardening

- The stored context is checked where it is read, and again when a flag list is built. A feature name must look like a cargo feature (`name`, `dep:name`, `pkg/feat`, `pkg?/feat`, no comma, no space, not starting with `-`); a target must look like a triple. Anything else is dropped (one warning per workspace and session; `:checkhealth` lists it). Before, `{"features": ["--config=build.rustc-wrapper=..."]}` in the state file went into cargo's argument list.
- Servers that did not initialise are SIGKILLed at exit only if they are direct children of this Neovim with the server's executable name; the pid is checked again when the signal is sent (parent, name, and the process start time from `/proc` on Linux), so a recycled pid is not signalled. When an initialised server of the same name runs too, only the newest children are killed (the ones that have not initialised yet); without `/proc` nothing is killed in that case. Neovim does not expose a server's pid, so this is as exact as it gets without it.
- The samply item builds into `target/<triple>/profiling/` when a target is stored, and records that binary (before, it looked in `target/profiling/` and failed). There is no samply item for a `wasm` target.
- Debounce timers are closed on a second `setup()` and at exit; "deps resolving" no longer leaves two timers per saved manifest registered for two minutes; the statusline state of dead clients is dropped; a burst of progress events costs one redraw per loop turn.

### Statusline component review (`xyno_rust.lsp_status`)

Read through for leaks and per-redraw cost. Found and fixed: the per-client state table was never pruned (one entry per server restart for the life of the session); every progress event scheduled its own `redrawstatus` (200 events in one tick meant 200 redraw calls, now one); `deps_begin` left two timers per saved manifest registered for 6 s and 120 s (now replaced per workspace and closed by `deps_clear`); the edit counter of a wiped buffer stayed. The specs for each are in `tests/server-supervision-statusline_spec.lua`. Kept as it was: the component is event driven and starts no timer while idle (the spec that asserts this still passes), it returns `""` outside Rust buffers, and it depends on `client.handlers` being replaceable after attach (rustaceanvim's own handler is called through). Not measured: the cost of one `component()` call (three `vim.lsp.get_clients` lookups and one `vim.diagnostic.count`); there is no number for it here.

### Measured (this machine, Linux, nvim 0.12.6, cargo 1.99.1)

`nvim -l bench/latency.lua <old-or-new checkout> <workspace> 5` (and `bench/gen.lua` for the synthetic one). Each number is the median of 5 cold runs, each in a fresh headless nvim whose main loop is fed a key every 4 ms from outside; "input stall" is the longest gap between two processed keys, so a blocked editor shows as one large gap. Before = commit `dbb2c0e`, after = this version.

| Workspace | Operation | total before / after | input stall before / after |
| --- | --- | --- | --- |
| demo/netwatch (1 crate, 3 files) | `:RustTargets` | 27 / 27 ms | 28 / 4.2 ms |
| | `:RustRoutes` | 44 / 43 ms | 46 / 29 ms |
| a real 114-target workspace (201 `.rs` files, 64 routes) | `:RustTargets` | 63.5 / 62.7 ms | 66 / 5.7 ms |
| | `:RustRoutes` | 335 / 325 ms | 337 / 29.6 ms |
| synthetic: 40 crates, 1640 files, 9600 routes (generated, not a real project) | `:RustTargets` | 29 / 30 ms | 31 / 5.1 ms |
| | `:RustRoutes` | 543 / 555 ms | 546 / 28.7 ms |
| netwatch with a `cargo` shim that sleeps 2 s (slow registry, toolchain download, network share) | `:RustTargets` | 4033 / 4031 ms | 4031 / 5.0 ms |
| | `:RustRoutes` | 2046 / 2045 ms | 2046 / 30 ms |
| | cold `root()` (sync wrapper) | 2015 / 2015 ms | 2018 / 2016 ms |
| | `root_async` | - / 2016 ms | - / 4.7 ms |

What this says: the work takes as long as before (the total does not improve, cargo and the parser are the same); what changed is that the editor keeps reading keys while it runs. The remaining ~29 ms stall in `:RustRoutes` is loading the tree-sitter parser and compiling the query in the first slice. The cold synchronous `root()` still blocks, now for at most 2 s instead of 5 s (the table row shows it hitting that cap with a 2 s shim); `root_async`, which the plugin's own commands use, does not. On a machine where cargo answers in 13-30 ms (all of the rows without the shim) the blocking was short; I saw the real problem once: `cargo metadata` in a workspace with a `rust-toolchain.toml` whose toolchain was not installed took 53 s on first run (longer than the old 30 s wait; I did not capture it again because the toolchain is installed now).

## Wiring it to the servers

The modules do not configure rust-analyzer or bacon-ls. This is how I wire them with rustaceanvim (taken from my config; it is not run by the specs here):

```lua
vim.g.rustaceanvim = {
  server = {
    on_exit = function(...)
      return require("xyno_rust.rust_restart").on_exit("rust-analyzer")(...)
    end,
    settings = function(root, default_settings)
      local settings = require("rustaceanvim.config.server").load_rust_analyzer_settings(
        root,
        { default_settings = vim.deepcopy(default_settings) }
      )
      local ctx = require("xyno_rust.rust_context")
      local cargo = ctx.ra_cargo(ctx.get(ctx.root(root and (root .. "/x"))))
      if cargo then
        local ra = settings["rust-analyzer"]
        ra.cargo = vim.tbl_extend("force", ra.cargo or {}, cargo)
      end
      return settings
    end,
  },
}
```

For bacon-ls, `on_exit` is the same with `"bacon_ls"`, and `before_init` rebuilds `extraArgs` from `rc.bacon_args(rc.get(root))`. The statusline component, with lualine: `lualine_x = { require("xyno_rust.lsp_status").component }`.

## How it works

The context is a small JSON file per workspace root. `:RustContext` writes it (under a lock file, then rename, so two Neovim instances cannot drop each other's entry), sends `workspace/didChangeConfiguration` to the rust-analyzer clients that serve the workspace, asks rustaceanvim to reload and restarts bacon-ls. The workspace root is the one `cargo locate-project --workspace` reports. The route picker is tree-sitter only: no LSP, it walks the `.rs` files. The status component is event driven (LSP progress, server status, text changes) and polls nothing while idle. Restart handling brings back a server that crashed (at most three times a minute) and restarts bacon-ls when Cargo.toml or Cargo.lock was saved, git HEAD moved or the manifest changed on disk.

## Platforms

- Linux: tested by the specs in this repository (`nvim -l tests/run.lua`), with a real rust-analyzer and cargo where the specs need them. The live bacon-ls half of the original supervision specs is not part of this repository, so bacon-ls itself is not exercised here.
- Windows: the Windows guards of the original code are kept (rename retries, backslash paths, `cmd.exe` for the profile entry), but I have no evidence for them from this repository. In xynovim's CI the Windows job passed overall (run 39673715062). The context, crate-metadata, tasks and routes specs were not skipped whole there, but the live rust-analyzer parts of the context spec are skipped as a known issue, and the supervision and statusline spec is skipped whole on Windows. On Windows the parts of `rust_restart` that accept only absolute paths starting with `/` do nothing.
- macOS: nothing tested here. In xynovim's CI the supervision and statusline spec is skipped on macOS, and the macOS runs there were not stable (one fully green run, others flaky or failed elsewhere), so I do not claim it works.

## Extracted from xynovim

These modules come from [xynovim](https://github.com/xynorash/xynovim), my Neovim configuration for Rust. The code is the same apart from the namespace (`config.*` became `xyno_rust.*`), `setup()` taking options, the picker and terminal calls checking that snacks.nvim is there, and a few renamed identifiers: the buffer variable `xynovim_stopped` is now `xyno_rust_stopped`, the autocommand groups are `xyno_rust_lsp_status` and `xyno_rust_restart`, and the crates.io user agent and cache directory carry this plugin's name.

## Tests

```sh
nvim -l tests/run.lua                      # specs, each file in its own headless nvim; state files go to a temp XDG_STATE_HOME
XYNO_TEST_RTP=/dir/with/parser nvim -l tests/run.lua   # a runtimepath holding parser/rust.so and parser/yaml.so
XYNO_LAZY=/path/to/lazy.nvim nvim --headless -u tests/e2e/init.lua -c "luafile tests/e2e/smoke.lua"
```

The other plugins' specs run against this one with `XYNO_RUST_DIR=/path/to/xyno-rust.nvim nvim -l tests/run.lua` in each of them. Specs that need cargo, rust-analyzer or a tree-sitter parser skip with a message when it is missing. CI builds the two parsers from pinned commits.

What is not covered here: the original xynovim specs ran `:RustRestart` and the status line against a live bacon-ls next to rust-analyzer (kill -9 of both servers, SIGSTOP-ed hung servers, repeated quick kills, FocusGained restarts). Those cases were not ported, so the restart and sweep logic has no real-process spec in this repository.

## License

MIT, Copyright (c) 2026 Xynorash.
