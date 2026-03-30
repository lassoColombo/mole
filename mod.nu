export use ./cfg
export module ./query
use ./completers.nu

# Open the query directory in the default editor
export def edit [queryfile?: string@"completers queryfile"] {
  let d = cfg querydir
  let t = if ($queryfile | is-not-empty) {
    [$d $queryfile] | path join
  } else {
    $d
  }
  nu -c $"cd ($d); ($env.EDITOR) ($t)"
}
