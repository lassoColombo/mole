# mole

A nushell framework to manage and query eterogeneous data-sources.

---

`mole` is the shared foundation for a family of small Nushell modules that wrap
data-source CLIs/APIs behind typed, completion-aware verbs. It provides
connection config, query/cache/exec plumbing, and shared completers.

**One principle: submodules depend on mole, never the reverse.** mole never
imports or enumerates submodules, so installing a submodule is only cloning a
sibling repo — mole's source is never edited, and there is no umbrella or
`sync`/codegen step. See [`DESIGN.md`](DESIGN.md).

> Submodule management and the version/compatibility contract were removed for
> now — mole core is currently connection-config + saved-query management plus the
> shared `lib/` plumbing. Install a submodule by cloning it next to `mole/` and
> adding a `use` line.

## Layout

```
<workspace>/                  # a flat workspace of sibling module repos
├── mole/                     # THIS repo — the core module
│   ├── mod.nu                # composition + `mole query edit/show/dir`
│   ├── cfg.nu                # `mole cfg show/file/dir/edit`
│   └── lib/                  # plumbing, imported per concern (never user-visible)
│       └── config.nu · conn.nu · cache.nu · query.nu · complete.nu
├── mole-sql/                 # a source submodule (stub): `use ../mole/lib/*.nu`
│   ├── mod.nu · mole.nuon
└── mole-vlogs/               # a source submodule (stub)
    ├── mod.nu · mole.nuon
```

## How it fits together

- **The user `use`s each module directly** (one `use` line each, always without
  `*`): `use mole`, `use mole-sql`, … Commands are prefixed by the module name →
  `mole cfg show`, `mole query dir`, `mole-sql select`.
- **`use mole` exposes only management commands** (`mole cfg …`, `mole query …`);
  the plumbing in `mole/lib/` is imported privately by `mod.nu` and never leaks.
  Submodules import the lib concerns they need directly, e.g. `use
  ../mole/lib/conn.nu` → `conn resolve` (file modules are imported with the `.nu`
  extension).
- **Registry self-assembles.** Each submodule's `export-env` runs on `use`,
  registering its `mole.nuon` into `$env.MOLE_REGISTRY`; loading several
  accumulates them. Its one consumer today is source-scoped `--source` completion.
- **Install by hand.** Clone a submodule next to `mole/` (`git clone <url>
  ../mole-<tool>`), then add a `use mole-<tool>` line. Update or pin with plain
  `git`. mole does not wrap this for now.

## Try it

```nushell
$env.NU_LIB_DIRS ++= ["/abs/path/to/workspace"]   # the dir CONTAINING mole/, mole-sql/, …

use mole
use mole-sql
use mole-vlogs

mole cfg show                # configured connections (secrets masked), by source
mole-sql set-connection prod-pg
mole-sql select id email --from users --where active --sort-by id --limit 5
```

Config lives at `~/.config/mole/connections.yaml` (a map **keyed by source**;
honors `$XDG_CONFIG_HOME`). A legacy flat `connections:` list is rejected at read;
convert it once with `scripts/migrate-connections-to-sections.nu`.

`mole-sql` and `mole-vlogs` here are **stubs** proving the integration
skeleton — real execution/typing lands later. `mole_old/` (a workspace sibling)
holds the original monolith for reference.
