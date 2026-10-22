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
  cmd = { "RustContext", "RustTargets", "RustTools", "RustRoutes", "RustNew", "RustRestart", "ActJob" },
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
  commands = true, -- :RustContext :RustTargets :RustTools :ActJob :RustNew :RustRoutes :RustRestart
  keymaps = false, -- false | true | { context = lhs, targets = lhs, ... }
  modules = {
    context = true, -- xyno_rust.rust_context
    tasks = true,   -- xyno_rust.rust_tasks
    routes = true,  -- xyno_rust.rust_routes
    status = true,  -- xyno_rust.lsp_status (autocommands)
    restart = true, -- xyno_rust.rust_restart (autocommands)
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

## Lua API

Every module can be required on its own. `:help xyno-rust-api` has the signatures.

| Module | Public functions |
| --- | --- |
| `xyno_rust` | `setup(opts)`, `defaults`, `default_keymaps` |
| `xyno_rust.fsutil` | `rename(tmp, dest)`, `slash(path)` |
| `xyno_rust.rust_context` | `root(path?)`, `get(root)`, `apply(root, ctx?)`, `pick()`, `reset()`, `describe(ctx?)`, `ra_cargo(ctx?)`, `cargo_flags(ctx?)`, `bacon_args(ctx?)`, `canon(path)` |
| `xyno_rust.rust_tasks` | `targets()`, `tools()`, `new(name?)`, `act_job()`, `doctests()`, `samply_cmd(build, bin)` |
| `xyno_rust.rust_routes` | `scan_source(src)`, `collect(root)`, `pick()` |
| `xyno_rust.rust_nav` | `goto_super()`, `local_usages()` |
| `xyno_rust.lsp_status` | `component()`, `rust_analyzer(buf?)`, `bacon(buf?)`, `deps(buf?)`, `bacon_failed(id)`, `deps_begin(root, buf?)`, `deps_clear(root?)` |
| `xyno_rust.rust_restart` | `on_exit(name)`, `restart()`, `sweep()`, `check_shadow()`, `manifest_saved(file, buf?)`, `server_pids()`, `kill_survivors(pids, ms?)`, `kill_uninitialised()`, `resume_servers()` |
| `xyno_rust.code_actions` | `request`, `request_wait`, `wait_for`, `filter`, `apply`, `apply_async`, `apply_all`, `resolve_async`, `clients`, `client_name` |
| `xyno_rust.crate_meta` | `metadata`, `metadata_async`, `invalidate`, `normalize`, `dependencies`, `member_of`, `root`, `registry_dir`, `source_dir`, `read_manifest`, `read_lib`, `parse_features`, `info`, `info_async`, `search`, `search_async`, `index_path`, `parse_index`, `valid_name`, `valid_version`, `compare_versions`, `is_known_path_head`, `exec`, `config`, `std_crates` |
| `xyno_rust.deps` | `snacks()` |

A context is `{ all = boolean, no_default = boolean, features = string[], target = string? }`; nothing stored means all features and the host target. It lives in `stdpath("state")/rust-context.json`, keyed by workspace root. The buffer variable `vim.b.xyno_rust_stopped` (`{ [server] = true }`) marks the buffers of a server that exited.

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
nvim -l tests/run.lua                      # specs, each file in its own headless nvim
XYNO_TEST_RTP=/dir/with/parser nvim -l tests/run.lua   # a runtimepath holding parser/rust.so and parser/yaml.so
XYNO_LAZY=/path/to/lazy.nvim nvim --headless -u tests/e2e/init.lua -c "luafile tests/e2e/smoke.lua"
```

Specs that need cargo, rust-analyzer or a tree-sitter parser skip with a message when it is missing. CI builds the two parsers from pinned commits.

What is not covered here: the original xynovim specs ran `:RustRestart` and the status line against a live bacon-ls next to rust-analyzer (kill -9 of both servers, SIGSTOP-ed hung servers, repeated quick kills, FocusGained restarts). Those cases were not ported, so the restart and sweep logic has no real-process spec in this repository.

## License

MIT, Copyright (c) 2026 Xynorash.
