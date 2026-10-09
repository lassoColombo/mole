# mole/lib/editor — the ONE way mole launches `$env.EDITOR`. Import individually:
# `use mole/lib/editor.nu` → `editor launch`.
#
# The editor is run DIRECTLY — never through `nu -c "<string>"`, which mangled
# quoting and the working directory. `$env.EDITOR` may carry flags (`code -w`);
# they are split off the command name.

# Open `target` in `$env.EDITOR` (default `vi`).
#
# With `--cwd`, the editor process starts in that directory; for vim-family editors
# the cwd is also pinned from inside the editor by a late `VimEnter` autocmd (it
# runs after the user's own config autocmds, so a plugin that resets the cwd on
# startup can't undo it). `cd` is scoped to this command, so the caller's directory
# is untouched.
@category mole-lib
@example "open a file" { launch "/tmp/query.sql" }
@example "open the query dir, with the editor rooted there" {
  launch "~/.config/mole/queries" --cwd "~/.config/mole/queries"
}
export def "launch" [
  target: string   # File or directory to open
  --cwd: string    # Working directory for the editor process (default: the caller's)
]: nothing -> any {
  let ed = ($env.EDITOR? | default "vi" | split row " " | where {|w| $w != "" })
  let cmd = ($ed | first)
  let flags = ($ed | skip 1)
  if ($cwd | is-not-empty) {
    cd $cwd
    if (($cmd | path basename) in ["nvim" "vim" "gvim" "mvim" "vi" "view"]) {
      return (^$cmd ...$flags -c $"autocmd VimEnter * cd ($cwd)" $target)
    }
  }
  ^$cmd ...$flags $target
}
