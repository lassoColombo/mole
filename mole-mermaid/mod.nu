# mole-mermaid — a SECOND user-facing exception to mole's file-only library rule
# (the first is mole-sqls). The pure libs (mole-sql, mole-promql) are imported by
# their file (`use mole-sql/sql.nu` → `sql …`); THIS package ships a mod.nu so it
# loads as `use mole-mermaid`, scoping its commands under the `mole-mermaid`
# prefix. It exposes two verbs:
#   - `mole-mermaid er-schema` — renders a mole SQL schema-cache record to Mermaid
#     `erDiagram` TEXT (pure; see ./mermaid.nu).
#   - `mole-mermaid render`    — renders arbitrary Mermaid TEXT to an image via
#     Docker (impure I/O; lives here).
# They compose: `… | mole-mermaid er-schema | mole-mermaid render`.
#
# UNLIKE mole-sqls, this package is FULLY standalone: mod.nu imports NOTHING from
# mole core. The schema record `er-schema` renders arrives on the PIPELINE — any
# mole SQL plugin produces it via `schema --full` — so mole-mermaid never touches
# connections, drivers, or the cache itself, and composes with every SQL driver
# (mysql, psql, duckdb, trino, …) for free:
#
#   mole-mysql schema --full | mole-mermaid er-schema | save schema.mmd
#   mole-psql  schema --full | mole-mermaid er-schema
#
# The pure rendering lives in ./mermaid.nu and is imported PRIVATELY (`use
# ./mermaid.nu`, never `export use`), so its `mermaid er-diagram` command and
# helpers never leak into `use mole-mermaid` — the public surface stays `er-schema`
# and `render`.

use ./mermaid.nu

# Rosé Pine (main) — hardcoded so the rendered plot adheres to the colorscheme
# WITHOUT being a tinty-managed config: these hexes are pinned here on purpose and
# do NOT re-render when the palette changes (see ~/.config/tinted-theming). Roles
# follow the scheme's doctrine — iris carries structure (entity borders), rose is
# the protagonist (relationship lines), the plum-night canvas + surface/overlay
# layers back the entities, text is the cool lavender-white foreground.
const ROSE_PINE = {
  base00: "#191724"  # Base — plum-night canvas
  base01: "#1f1d2e"  # Surface — entity fill / odd attr rows
  base02: "#26233a"  # Overlay — even attr rows
  base04: "#8c88a6"  # Subtle — muted lines / secondary borders
  base05: "#e0def4"  # Text — foreground
  base08: "#eb6f92"  # Love — errors/accents
  base09: "#f6c177"  # Gold — data
  base0A: "#ebbcba"  # Rose — relationship lines (protagonist)
  base0D: "#c4a7e7"  # Iris — structural borders (carries the code)
  base13: "#fff0ee"  # Bright Rose — entity titles / headers
}

# The mermaid-cli theme config that paints an erDiagram in Rosé Pine. Built on the
# `base` theme so every colour is driven by these variables (no leftover mermaid
# defaults). Pure data — mapped from $ROSE_PINE roles above.
def rose-pine-mermaid-config []: nothing -> record {
  {
    theme: "base"
    themeVariables: {
      darkMode: true
      fontFamily: "monospace"
      background: $ROSE_PINE.base00
      primaryColor: $ROSE_PINE.base01           # entity fill
      primaryBorderColor: $ROSE_PINE.base0D      # entity border — iris
      primaryTextColor: $ROSE_PINE.base05        # entity text
      secondaryColor: $ROSE_PINE.base02
      secondaryBorderColor: $ROSE_PINE.base04
      tertiaryColor: $ROSE_PINE.base02
      tertiaryBorderColor: $ROSE_PINE.base04
      lineColor: $ROSE_PINE.base0A               # relationship lines — rose
      textColor: $ROSE_PINE.base05
      mainBkg: $ROSE_PINE.base01
      nodeBorder: $ROSE_PINE.base0D
      # ER-diagram specifics. Current mermaid paints the alternating attribute
      # rows from `rowOdd`/`rowEven` (the old `attributeBackgroundColor*` names are
      # ignored — mermaid then derives them by DARKENING mainBkg, which crushes the
      # rows to near-black). Pin them so odd rows sit on surface and even rows on
      # overlay — the same two-layer plum the entity fill uses.
      rowOdd: $ROSE_PINE.base01                  # odd attr rows — surface
      rowEven: $ROSE_PINE.base02                 # even attr rows — overlay
      # Relationship-label chip: otherwise mermaid darkens secondaryColor by 30%,
      # which drifts off-hue (a muddy olive); pin it to the overlay plum.
      edgeLabelBackground: $ROSE_PINE.base02     # relationship label bg — overlay
    }
    # Native <text> labels instead of HTML-in-<foreignObject>. Two wins: it renders
    # identically here, and it lets rsvg-convert turn the svg into a dark VECTOR pdf
    # (`render -f pdf`) — librsvg cannot render foreignObject, so with the default
    # HTML labels the pdf would come out blank.
    htmlLabels: false
    # Layout engine: ELK gives a more COMPACT, orthogonal disposition than the
    # default dagre (measured ~26% narrower on a wide schema; edges route as clean
    # right angles). Bundled in the mermaid-cli image.
    layout: "elk"
    # ER sizing: shrink from mermaid's roomy defaults (fontSize 12, entityPadding 15,
    # minEntityWidth 100, minEntityHeight 75, diagramPadding 20) so a many-table
    # schema packs tighter — combined with ELK this is ~36% narrower / 20% shorter.
    er: {
      fontSize: 11
      entityPadding: 6
      minEntityWidth: 40
      minEntityHeight: 24
      diagramPadding: 8
    }
  }
}

# Wrap a rendered SVG in a minimal HTML page that is an interactive PAN/ZOOM viewer
# on a full `bg` canvas. Two problems it solves: (1) a bare .svg leaves the browser's
# own white page around the diagram, and (2) browser page-zoom caps out, so a big
# schema can't be zoomed in far enough. Here the whole page is the plum canvas, and a
# tiny inline script gives UNBOUNDED wheel-zoom (toward the cursor) + drag-to-pan +
# double-click-to-fit, opening fitted to the viewport. It stays vector (crisp at any
# zoom). Built by concatenation, NOT `$"..."` (the SVG + JS contain parens an
# interpolation would mis-read); the static HTML/CSS/JS are nushell raw strings.
def "wrap-svg-html" [svg: string, bg: string]: nothing -> string {
  let body = ($svg | str replace --regex '^\s*<\?xml[^>]*\?>\s*' '')
  let head = (r#'<!doctype html><html><head><meta charset="utf-8"><title>schema</title><style>html,body{margin:0;height:100%;overflow:hidden;background:'# + $bg + r#'}#vp{position:fixed;inset:0;overflow:hidden;cursor:grab}#stage{position:absolute;top:0;left:0;transform-origin:0 0}#hint{position:fixed;bottom:10px;left:12px;font:12px monospace;color:#908caa;opacity:.6;user-select:none;pointer-events:none}</style></head><body><div id="vp"><div id="stage">'#)
  let tail = r#'</div></div><div id="hint">scroll = zoom · drag = pan · double-click = fit</div><script>(function(){var vp=document.getElementById("vp"),stage=document.getElementById("stage"),svg=stage.querySelector("svg");if(!svg)return;var vb=svg.viewBox&&svg.viewBox.baseVal,W=(vb&&vb.width)||svg.getBBox().width,H=(vb&&vb.height)||svg.getBBox().height;svg.removeAttribute("width");svg.removeAttribute("height");svg.style.width=W+"px";svg.style.height=H+"px";svg.style.maxWidth="none";var s=1,x=0,y=0,drag=false,px=0,py=0;function apply(){stage.style.transform="translate("+x+"px,"+y+"px) scale("+s+")";}function fit(){var r=vp.getBoundingClientRect();s=Math.min(r.width/W,r.height/H)*0.95;x=(r.width-W*s)/2;y=(r.height-H*s)/2;apply();}vp.addEventListener("wheel",function(e){e.preventDefault();var r=vp.getBoundingClientRect(),mx=e.clientX-r.left,my=e.clientY-r.top,f=Math.exp(-e.deltaY*0.0015),ns=s*f;x=mx-(mx-x)*(ns/s);y=my-(my-y)*(ns/s);s=ns;apply();},{passive:false});vp.addEventListener("mousedown",function(e){drag=true;px=e.clientX-x;py=e.clientY-y;vp.style.cursor="grabbing";});window.addEventListener("mousemove",function(e){if(drag){x=e.clientX-px;y=e.clientY-py;apply();}});window.addEventListener("mouseup",function(){drag=false;vp.style.cursor="grab";});vp.addEventListener("dblclick",fit);window.addEventListener("resize",fit);fit();})();</script></body></html>'#
  $head + $body + $tail
}

# Render a mole SQL schema-cache record as a Mermaid ER-diagram string.
#
# Pipe in the record a SQL plugin returns from `schema --full`
# ({meta?, tables, columns, constraints}). Produces a Mermaid entity-relationship
# diagram (`erDiagram`): one entity per table carrying its columns (type, PK/FK/UK
# markers and comments) and one relationship per foreign key (the left
# cardinality reflects whether the FK is mandatory). The result is a string —
# redirect or pipe it where you need it.
@category mole-mermaid
@example "render a connection's schema to a .mmd file" {
  mole-mysql schema --full | mole-mermaid er-schema | save schema.mmd
}
@example "render a Postgres connection's schema" {
  mole-psql schema --full -c my-pg | mole-mermaid er-schema
}
@example "narrow the diagram to just the tables you care about (filtered at the source)" {
  mole-psql schema --full --include "users,orders,order_items" -c my-pg | mole-mermaid er-schema
}
@example "or exclude the noise (foreign keys into dropped tables are pruned too)" {
  mole-psql schema --full --exclude "*_audit,django_*" -c my-pg | mole-mermaid er-schema
}
export def "er-schema" []: record -> string {
  $in | mermaid er-diagram
}

# Render Mermaid diagram text (from stdin) to an image, with full control over
# format, resolution, size, colours and destination.
#
# Needs Docker; pulls minlag/mermaid-cli on first use. Pipe in ANY Mermaid source
# — the `erDiagram` string `er-schema` produces, or a hand-written flowchart /
# sequence / … diagram.
#
# RESOLUTION: a PNG's sharpness is driven by `--scale` (mermaid-cli's Puppeteer
# pixel-density factor), which defaults to 3 here — mmdc's own default of 1 is what
# makes raw PNGs look soft/low-res. Raise it for print, drop to 1 for a quick draft.
# `--width`/`--height` set the page mermaid lays the diagram out in (a wider page
# lets a big ER diagram breathe before it is rasterized). Both are moot for SVG,
# which is vector — prefer SVG for the sharpest, smallest artefact and reach for
# PNG (with a high `--scale`) only when a raster is actually required.
#
# THEME: by default the pinned Rosé Pine config paints the plot (plum-night canvas).
# `--theme` swaps in a mermaid built-in (default|forest|dark|neutral); `--config`
# supplies your own mermaid JSON config; `--css` layers a stylesheet; `--background`
# overrides the canvas (any colour, or `transparent` to sit on a page).
#
# FORMATS: svg | png | pdf | html — all keep the dark canvas:
#  - pdf : a dark VECTOR pdf, converted from the svg by rsvg-convert (needs
#          `librsvg`). Opens in a native viewer (Preview) that zooms far past a
#          browser's limit — the best way to browse a big schema. NB: mermaid-cli's
#          OWN pdf is always white (it omits Puppeteer's printBackground), which is
#          why we go via rsvg instead; that also needs native <text> (config sets
#          htmlLabels:false).
#  - html: the svg on a full dark page that is also an inline pan/zoom viewer
#          (unbounded wheel-zoom + drag) — for viewing in a browser.
#  - svg : the raw vector artefact (dark canvas via the svg's own background).
#  - png : a dark raster at `--scale` density.
#
# OUTPUT: `--output PATH` writes the result there and its extension picks the format
# (overriding `--format`); otherwise a temp file is produced and opened, unless
# `--no-open`, which returns the path instead.
#
#   mole-psql schema --full | mole-mermaid er-schema | mole-mermaid render -f png --scale 4
#   "graph TD; A-->B" | mole-mermaid render -o ~/flow.png --background transparent
#   open diagram.mmd | mole-mermaid render --theme dark --width 1600 --no-open
@category mole-mermaid
@example "high-resolution PNG to a chosen path, without opening it" {
  "graph TD; A-->B" | mole-mermaid render -o /tmp/flow.png --scale 4 --no-open
}
@example "transparent background for embedding in a document" {
  "graph TD; A-->B" | mole-mermaid render -f png --background transparent
}
@example "a dark VECTOR pdf you can browse (and zoom far) in Preview" {
  mole-psql schema --full -c my-pg | mole-mermaid er-schema | mole-mermaid render -f pdf
}
@example "view a schema in the browser on a full dark pan/zoom page" {
  mole-psql schema --full -c my-pg | mole-mermaid er-schema | mole-mermaid render -f html
}
export def "render" [
  --format(-f): string = "svg"   # svg | png | pdf (dark vector, via librsvg) | html (dark pan/zoom page); an --output extension overrides this
  --output(-o): path             # write the image here (its extension overrides --format); else a temp file
  --scale(-s): number = 3        # pixel-density multiplier — the PNG resolution knob (mmdc default is 1)
  --width(-w): int               # page width in px mermaid lays out in (mmdc default 800)
  --height(-H): int              # page height in px (mmdc default 600)
  --background(-b): string       # canvas colour, or `transparent` (default: the Rosé Pine plum canvas)
  --theme(-t): string            # mermaid built-in theme instead of Rosé Pine: default | forest | dark | neutral
  --config: path                 # your own mermaid JSON config file (replaces the Rosé Pine config)
  --css: path                    # extra CSS file layered onto the diagram
  --quiet(-q)                    # suppress mermaid-cli log output
  --no-open                      # don't open the result; return its path instead
]: string -> any {
  # ---- resolve + validate the format (an --output extension wins) ----
  let fmt = if ($output != null) {
    let ext = ($output | path parse | get extension | str lowercase)
    if ($ext in ["svg" "png" "pdf" "html"]) { $ext } else { $format }
  } else { $format }
  if ($fmt not-in ["svg" "png" "pdf" "html"]) {
    error make {msg: $"render: unsupported format '($fmt)' — use svg, png, pdf or html"}
  }
  # `html` and `pdf` are both derived from the svg: mermaid-cli renders the svg; we
  # then wrap it (html) or convert it with rsvg-convert (pdf — for a dark VECTOR page,
  # since mermaid-cli's own pdf is always white). So drive mmdc with svg for both.
  let render_fmt = (if $fmt in ["html" "pdf"] { "svg" } else { $fmt })
  if ($theme != null) and ($theme not-in ["default" "forest" "dark" "neutral"]) {
    error make {msg: $"render: unknown --theme '($theme)' — use default, forest, dark or neutral"}
  }
  if ($scale <= 0) { error make {msg: "render: --scale must be greater than 0"} }
  if ($config != null) and (not ($config | path exists)) { error make {msg: $"render: --config file not found: ($config)"} }
  if ($css != null) and (not ($css | path exists)) { error make {msg: $"render: --css file not found: ($css)"} }

  # ---- stage inputs into a temp dir Docker can see ----
  let dir = (mktemp -d)
  $in | save -f ($dir | path join "diagram.mmd")
  # Theme precedence: a custom --config wins; then a built-in --theme (no config
  # file); otherwise the pinned Rosé Pine config. `-c` and `-t` are mutually
  # exclusive so the chosen one fully owns the palette.
  let use_config = ($theme == null)
  if $use_config {
    if ($config != null) {
      cp $config ($dir | path join "theme.json")
    } else {
      rose-pine-mermaid-config | to json | save -f ($dir | path join "theme.json")
    }
  }
  if ($css != null) { cp $css ($dir | path join "custom.css") }
  # Default canvas: the Rosé Pine plum only while we own the theme; under a built-in
  # --theme fall back to mermaid-cli's own default so its palette stays coherent.
  let bg = ($background | default (if $use_config { $ROSE_PINE.base00 } else { "white" }))

  # ---- build the mmdc argument list (only the flags that apply) ----
  let args = ([
      "-i" "/data/diagram.mmd" "-o" $"/data/diagram.($render_fmt)" "-e" $render_fmt "-b" $bg "-s" $scale
    ]
    ++ (if $use_config { ["-c" "/data/theme.json"] } else { [] })
    ++ (if ($theme != null) { ["-t" $theme] } else { [] })
    ++ (if ($width != null) { ["-w" $width] } else { [] })
    ++ (if ($height != null) { ["-H" $height] } else { [] })
    ++ (if ($css != null) { ["-C" "/data/custom.css"] } else { [] })
    ++ (if $quiet { ["-q"] } else { [] }))

  ^docker run --rm -v $"($dir):/data" minlag/mermaid-cli ...$args

  # Post-process the svg for the derived formats:
  #  - html: wrap in a dark-background pan/zoom page (see wrap-svg-html).
  #  - pdf : convert to a dark VECTOR pdf with rsvg-convert, compositing the canvas
  #          colour (mermaid-cli's own pdf omits the background → always white).
  #          rsvg needs native <text>, which the Rosé Pine config guarantees via
  #          htmlLabels:false (librsvg cannot render mermaid's foreignObject labels).
  if $fmt == "html" {
    wrap-svg-html (open --raw ($dir | path join "diagram.svg")) $bg | save -f ($dir | path join "diagram.html")
  } else if $fmt == "pdf" {
    if (which rsvg-convert | is-empty) {
      error make {msg: "render: -f pdf needs rsvg-convert for a dark vector PDF — install librsvg (`brew install librsvg`)"}
    }
    let rsvg_bg = (if $bg == "transparent" { "none" } else { $bg })
    ^rsvg-convert -b $rsvg_bg -f pdf ($dir | path join "diagram.svg") -o ($dir | path join "diagram.pdf")
  }

  # ---- place the result (a chosen --output, else the temp file) ----
  let tmp_out = ($dir | path join $"diagram.($fmt)")
  let out = if ($output != null) {
    let dest = ($output | path expand)
    let parent = ($dest | path dirname)
    if not ($parent | path exists) { error make {msg: $"render: output directory does not exist: ($parent)"} }
    mv --force $tmp_out $dest
    $dest
  } else { $tmp_out }

  if not $no_open { start $out; return }
  return $out
}
