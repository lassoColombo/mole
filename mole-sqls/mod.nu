# mole-sqls — the ONE user-facing exception to mole's file-only library rule. The
# pure libs (mole-sql, mole-promql) are imported by their file (`use mole-sql/sql.nu`
# → `sql …`); THIS package ships a mod.nu so it loads as `use mole-sqls`, scoping
# its commands under the `mole-sqls` prefix. It exposes EXACTLY ONE verb —
# `mole-sqls cfg translate` — which renders mole's connections as a `sqls`
# language-server config.
#
# The pure translation lives in ./sqls.nu and is imported PRIVATELY (`use ./sqls.nu`,
# never `export use`), so its `sqls drivers/entry/config` helpers never leak into
# `use mole-sqls` — the public surface stays the single `cfg translate`. mod.nu adds
# only the I/O the pure core refuses to do: reading connections from mole core.

use mole/lib/conn.nu
use ./sqls.nu

# Render mole's connections as a `sqls` language-server config record.
#
# Reads every connection from mole's connections.yaml (`conn list`), keeps the ones
# whose driver sqls supports (psql → postgresql, mysql → mysql; other drivers are
# dropped), and returns `{lowercaseKeywords, connections}` — the shape sqls's
# config.yml expects, in connections.yaml order (sqls treats the first as default).
#
# It returns DATA, not a file — render and place it yourself:
#   `mole-sqls cfg translate | to yaml | save --force ~/.config/sqls/config.yml`
# or write a temp file to feed `sqls -config`. Per-connection enrichment (params,
# sshConfig, a full dataSourceName, a driver override, …) flows through from each
# connection's optional `sqls: {...}` overlay in connections.yaml.
@category mole-sqls
@example "render mole's connections as a sqls config.yml" {
  mole-sqls cfg translate | to yaml
}
@example "peek at the translated connections" {
  mole-sqls cfg translate | get connections | select alias driver host
}
export def "cfg translate" [
  --lowercase-keywords = true   # sqls top-level `lowercaseKeywords` setting
]: nothing -> record {
  conn list | sqls config --lowercase-keywords $lowercase_keywords
}
