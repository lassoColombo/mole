# mole

`mole` is the shared foundation for a family of small Nushell modules that wrap
data-source CLIs/APIs (`mole-sql`, `mole-vlogs`, …) behind typed,
completion-aware verbs. It provides connection config, query/cache/exec
plumbing, shared completers, and a **versioned integration contract** that
submodules plug into.

**One principle: submodules depend on mole, never the reverse.** mole never
imports or enumerates submodules, so installing a submodule is only cloning a
sibling repo — mole's source is never edited, and there is no umbrella or
`sync`/codegen step. See [`DESIGN.md`](DESIGN.md).

## Layout

```
<workspace>/                  # a flat workspace of sibling module repos
├── mole/                     # THIS repo — the core module
│   ├── mod.nu                # composition + `mole api-version`, `mole edit`
│   ├── cfg.nu                # `mole cfg show/file/querydir/edit`
│   ├── submodules.nu         # `mole submodules sources/doctor/install/uninstall/update/checkout`
│   ├── mole.nuon             # mole's single tag: { api }
│   └── lib/                  # plumbing, imported per concern (never user-visible)
│       └── version.nu · config.nu · conn.nu · cache.nu · query.nu · complete.nu
├── mole-sql/                 # a source submodule (stub): `use ../mole/lib/*.nu`
│   ├── mod.nu · plugin.nuon
└── mole-vlogs/               # a source submodule (stub)
    ├── mod.nu · plugin.nuon
```

## How it fits together

- **The user `use`s each module directly** (one `use` line each, always without
  `*`): `use mole`, `use mole-sql`, … Commands are prefixed by the module name →
  `mole cfg show`, `mole submodules sources`, `mole-sql select`.
- **`use mole` exposes only management commands**; the plumbing in `mole/lib/`
  is imported privately by `mod.nu` and never leaks. Submodules import the lib
  concerns they need directly, e.g. `use ../mole/lib/conn.nu` → `conn resolve`
  (file modules are imported with the `.nu` extension).
- **Registry self-assembles.** Each submodule's `export-env` runs on `use`,
  registering its `plugin.nuon` into `$env.MOLE_REGISTRY` and version-gating with
  `version require-api`. Loading several accumulates them.
- **Versions.** mole has one tag — its `api` (contract) version in `mole.nuon`,
  read at runtime. Each submodule declares the `api` it targets plus its own
  `version`; `mole submodules doctor` checks compatibility with native semver.
- **Lifecycle = git.** `mole submodules install/uninstall/update/checkout`
  clone/remove/pull/checkout siblings. `checkout` takes a native-semver tag (no
  `v` prefix), with completion listing a submodule's valid tags newest-first.

## Try it

```nushell
$env.NU_LIB_DIRS ++= ["/abs/path/to/workspace"]   # the dir CONTAINING mole/, mole-sql/, …

use mole
use mole-sql
use mole-vlogs

mole submodules sources      # installed submodules + loaded/ready
mole submodules doctor       # api compatibility + missing CLIs
mole-sql set-connection prod-pg
mole-sql select id email --from users --where active --sort-by id --limit 5
```

Config lives at `~/.config/mole/connections.yaml` (flat, driver-keyed; honors
`$XDG_CONFIG_HOME`). Convert a legacy sectioned config once with
`migrate-connections.nu`.

`mole-sql` and `mole-vlogs` here are **stubs** proving the integration
skeleton — real execution/typing lands later. `mole_old/` (a workspace sibling)
holds the original monolith for reference.
