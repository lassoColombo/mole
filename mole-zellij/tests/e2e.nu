# mole-zellij end-to-end checks.
#
# NOT a nutest suite: mole-zellij is an orchestration package (its mod.nu imports
# mole/lib/*), and nutest discovers tests with `nu --no-config-file`, which drops
# the NU_LIB_DIRS your env.nu sets — so it cannot parse a cross-module mod.nu (every
# nutest suite in this repo targets a PURE core file instead). This script is run by
# a normal, config-loading nu, which resolves the workspace through NU_LIB_DIRS:
#
#   NU_LIB_DIRS="$PWD" nu mole-zellij/tests/e2e.nu   # from the workspace root
#
# Each check isolates state under a fresh temp $XDG_CONFIG_HOME / $XDG_CACHE_HOME.
use std/assert
use mole-zellij
use mole/lib/cache.nu

# ---- install: copies the shipped (editor-only) layout into the layouts dir ----
$env.XDG_CONFIG_HOME = (mktemp -d)
let dest = (mole-zellij install)
assert ($dest | path exists) "install writes the layout file"
let content = (open --raw $dest)
assert ($content | str contains 'tab name="mole"') "installed layout defines the mole tab"
assert ($content | str contains 'name="editor"') "installed layout has the editor pane"
assert ($content | str contains 'floating_panes') "layout declares its own floating_panes (blocks the session's inherited scratch)"
assert ($content | str contains 'name="query"') "the single floating pane is the query REPL"
assert ($content | str contains 'width "90%"') "the floating query pane is 90% wide"
print "ok  install writes the layout (editor + one 90×90 floating query)"

# ---- install: refreshes an out-of-date layout, then no-ops when current ----
$env.XDG_CONFIG_HOME = (mktemp -d)
mkdir ($env.XDG_CONFIG_HOME | path join "zellij" "layouts")
let managed = ($env.XDG_CONFIG_HOME | path join "zellij" "layouts" "mole.kdl")
"OLD" | save -f $managed
mole-zellij install                                  # OLD != shipped → refresh
assert (not ((open --raw $managed) == "OLD")) "install heals a stale layout"
let synced = (open --raw $managed)
mole-zellij install                                  # now current → no-op
assert equal (open --raw $managed) $synced "install is a no-op when up to date"
print "ok  install self-heals a stale layout (fixes the duplicate-pane bug)"

# ---- dev --dry-run: resolves connection -> driver/module/schema pipeline ----
$env.XDG_CONFIG_HOME = (mktemp -d)
mkdir ($env.XDG_CONFIG_HOME | path join "mole")
{connections: {psql: [{name: "app", host: "localhost", port: 5432, user: "me", password: "x", database: "d"}]}}
| to yaml | save -f ($env.XDG_CONFIG_HOME | path join "mole" "connections.yaml")
let plan = (mole-zellij dev "app" --dir "/tmp/proj" --dry-run)
assert equal $plan.connection "app"
assert equal $plan.driver "psql"
assert equal $plan.module "mole-psql"
assert equal $plan.layout "mole"
assert equal $plan.dir "/tmp/proj" "--dir is honoured"
# without --dir, the tab (editor + query) roots at the mole QUERY dir, not pwd
let def_plan = (mole-zellij dev "app" --dry-run)
assert equal $def_plan.dir ($env.XDG_CONFIG_HOME | path join "mole" "queries") "--dir defaults to the mole query dir"
assert ($plan.schema_cmd | str contains "mole-psql schema --full -c app") "schema pipeline queries the driver"
assert ($plan.schema_cmd | str contains "mole-mermaid er-schema") "schema pipeline renders the ER diagram"
assert ($plan.schema_cmd | str contains "mole-mermaid render -f pdf") "default renders a dark vector PDF (opens in Preview)"
print "ok  dev --dry-run defaults to a dark vector PDF schema"

# other formats still selectable
let html_plan = (mole-zellij dev "app" --format "html" --dry-run)
assert ($html_plan.schema_cmd | str contains "mole-mermaid render -f html") "--format html is honoured"
print "ok  dev --format html overrides the default"

# ---- enter: activates the connection dev recorded ----
$env.XDG_CACHE_HOME = (mktemp -d)
{driver: "psql", connection: "app"} | cache write (cache path "zellij" "current")
$env.MOLE_CURRENT = {}
mole-zellij enter
assert equal ($env.MOLE_CURRENT.psql) "app" "enter flips MOLE_CURRENT for the driver"
print "ok  enter activates the recorded connection"

# ---- enter: no-op when nothing recorded ----
$env.XDG_CACHE_HOME = (mktemp -d)
$env.MOLE_CURRENT = {existing: "x"}
mole-zellij enter
assert equal $env.MOLE_CURRENT {existing: "x"} "enter leaves MOLE_CURRENT alone with no marker"
print "ok  enter is a no-op with no marker"

print $"(ansi green_bold)all mole-zellij checks passed(ansi reset)"
