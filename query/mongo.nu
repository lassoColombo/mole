use "../cfg"
use "../helpers.nu"
use "../completers.nu"

# Run a query against a MongoDB datasource
export def main [
  --query(-q): string
  --file(-f): string@"completers queryfile"
  --connection(-c): string@"completers mongo-connection"
  --database(-d): string
  --port(-p): int
  --user(-u): string
  --host(-h): string
  --password(-P): string
] {
  if ($connection | is-not-empty) { cfg set $connection }
  let conf = helpers resolve-conf $connection
  let q = helpers resolve-query $query $file (cfg querydir)
  helpers danger-check $q
  let uri = $"mongodb://($user | default $conf.user):($password | default $conf.password)@($host | default $conf.host):($port | default $conf.port)/($database | default $conf.database)?authSource=($conf.database)"
  let js = {query: $q} | format pattern "(() => {{
    const result = {query};
    if (result?.toArray) {{ return EJSON.stringify(result.toArray(), null, 2); }}
    return EJSON.stringify(result, null, 2);
  }})()"
  let result = mongosh $uri --quiet --eval $js | complete
  if $result.exit_code != 0 { error make {msg: $"($result.stderr)\n($result.stdout)"} }
  try { $result.stdout | from json } catch { $result.stdout }
}
