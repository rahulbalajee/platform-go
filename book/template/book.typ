// =============================================================================
// Platform Go: book design system
//
// Everything visual lives here: page geometry, typography, colour, code
// listings that are read straight from the companion repository, terminals,
// callouts, chapter openers, and the cover.
// Compile from the repository root:  typst compile --root . book/main.typ
// =============================================================================

#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge

// ---- Palette ----------------------------------------------------------------
#let c = (
  ink: rgb("#1c2230"),
  muted: rgb("#5b6475"),
  faint: rgb("#8a93a3"),
  navy: rgb("#0b1d33"),
  navy2: rgb("#12304f"),
  go: rgb("#00add8"),     // Go brand cyan
  godark: rgb("#007d9c"), // Go brand dark cyan
  rule: rgb("#dfe3ea"),
  codebg: rgb("#f7f8fa"),
  codehead: rgb("#eef1f5"),
  term: rgb("#0f1720"),
  termtext: rgb("#d5dde8"),
  termprompt: rgb("#5ad2f4"),
  note: rgb("#0969da"),
  tip: rgb("#1a7f37"),
  warn: rgb("#b35900"),
  prod: rgb("#7c3aed"),
  interview: rgb("#007d9c"),
  internals: rgb("#475569"),
  new: rgb("#00add8"),
)

#let fonts = (
  serif: ("Source Serif 4",),
  sans: ("Inter",),
  mono: ("JetBrains Mono",),
)

#let book-title = "Platform Go"
#let book-subtitle = "Production-Grade Tools, Operators, Services, and AI Systems for Platform Engineering"
#let book-author = "Rahul Balajee"
#let repo-url = "github.com/rahulbalajee/platform-go"

// ---- Snippets from the companion repository ----------------------------------
// Regions are delimited Go-present-style:  // START name OMIT ... // END name OMIT
// Any line containing OMIT is dropped, so markers never leak into the book.
#let _trim-blank(lines) = {
  let ls = lines
  while ls.len() > 0 and ls.first().trim() == "" { ls = ls.slice(1) }
  while ls.len() > 0 and ls.last().trim() == "" { ls = ls.slice(0, ls.len() - 1) }
  ls
}

#let read-source(path, region: none) = {
  let lines = read(path).split("\n")
  if region != none {
    let start = lines.position(l => l.contains("START " + region + " OMIT"))
    let end = lines.position(l => l.contains("END " + region + " OMIT"))
    assert(start != none, message: "region '" + region + "' not found in " + path)
    assert(end != none, message: "region '" + region + "' has no END in " + path)
    lines = lines.slice(start + 1, end)
  }
  _trim-blank(lines.filter(l => not l.contains("OMIT"))).join("\n")
}

#let _lang-of(path) = {
  let ext = path.split(".").last()
  (go: "go", yaml: "yaml", yml: "yaml", json: "json", sh: "bash", typ: "typst",
   mod: "go", toml: "toml", proto: "protobuf", md: "markdown", Dockerfile: "dockerfile").at(ext, default: none)
}

// listing: a framed code block with an optional file tab.
#let listing(body, file: none, caption: none, lines: 0) = {
  block(
    width: 100%, breakable: lines > 26, above: 1.1em, below: 1.1em,
    stroke: 0.6pt + c.rule, radius: 5pt, clip: true,
  )[
    #if file != none {
      block(
        width: 100%, fill: c.codehead, inset: (x: 10pt, y: 5.5pt), below: 0pt,
        stroke: (bottom: 0.6pt + c.rule),
      )[
        #set text(font: fonts.mono, size: 7.4pt, fill: c.muted)
        #box(width: 6pt, height: 6pt, radius: 3pt, fill: c.go, baseline: -0.5pt)
        #h(5pt) #file
        #if caption != none { h(1fr); text(font: fonts.sans, size: 7.2pt, style: "italic")[#caption] }
      ]
    }
    #block(width: 100%, fill: c.codebg, inset: (x: 11pt, y: 9pt), above: 0pt, body)
  ]
}

// src: show code from the repo. `path` is repo-relative without leading slash.
// Fold an over-long `// +marker` comment (kubebuilder markers must be one
// line in the source) at commas or spaces, marking continuations with ↪.
// book/scripts/check_widths.py implements the same rule.
#let fold-width = 86
#let _width(s) = s.replace("\t", "    ").clusters().len()
#let _fold-marker(line) = {
  let body = line.trim(at: start)
  if _width(line) <= fold-width or not body.starts-with("// +") { return line }
  let indent = line.slice(0, line.len() - body.len())
  let tokens = ()
  let cur = ""
  for ch in body.clusters() {
    cur += ch
    if ch == "," or ch == " " { tokens.push(cur); cur = "" }
  }
  if cur != "" { tokens.push(cur) }
  let lines = ()
  let acc = indent
  let cont = indent + "//   ↪ "
  for t in tokens {
    if _width(acc + t.trim(at: end)) > fold-width and acc.trim() != "" and acc != cont {
      lines.push(acc.trim(at: end))
      acc = cont + t.trim(at: start)
    } else {
      acc += t
    }
  }
  lines.push(acc.trim(at: end))
  lines.join("\n")
}

#let src(path, region: none, lang: auto, caption: none) = {
  let code = read-source("/" + path, region: region)
  code = code.split("\n").map(_fold-marker).join("\n")
  let lang = if lang == auto { _lang-of(path) } else { lang }
  listing(file: path, caption: caption, lines: code.split("\n").len(), raw(code, lang: lang, block: true))
}

// code: an inline-authored block (for "bad" examples, sketches, YAML, etc.)
#let code(body, file: none, caption: none) = {
  let n = if body.has("text") { body.text.split("\n").len() } else { 0 }
  listing(file: file, caption: caption, lines: n, body)
}

// ---- Terminal sessions --------------------------------------------------------
// Lines starting with "$ " are commands; everything else is output.
#let terminal(body, title: none, size: 7.2pt) = {
  let text-of(b) = if type(b) == str { b } else if b.has("text") { b.text } else { b }
  let content = text-of(body)
  // Lines continuing a command (previous command line ends in "\") are
  // styled as part of the command.
  let cont = ()
  let in-cmd = false
  for (i, l) in content.split("\n").enumerate() {
    if in-cmd { cont.push(i + 1) }
    in-cmd = (l.starts-with("$ ") or in-cmd) and l.trim(at: end).ends-with("\\")
  }
  block(
    width: 100%, breakable: content.split("\n").len() > 30, above: 1.1em, below: 1.1em,
    fill: c.term, radius: 5pt, clip: true,
  )[
    #block(width: 100%, inset: (x: 10pt, top: 6pt, bottom: 5pt), below: 0pt)[
      #for col in (rgb("#ff5f57"), rgb("#febc2e"), rgb("#28c840")) {
        box(width: 6.5pt, height: 6.5pt, radius: 3.25pt, fill: col)
        h(3.5pt)
      }
      #if title != none {
        h(6pt); text(font: fonts.mono, size: 7pt, fill: c.faint)[#title]
      }
    ]
    #block(width: 100%, inset: (x: 11pt, top: 3pt, bottom: 10pt), above: 0pt)[
      #set text(font: fonts.mono, fill: c.termtext)
      #show raw: set text(font: fonts.mono, size: size, ligatures: false)
      #set par(justify: false, leading: 0.55em)
      #show raw.line: it => {
        if it.text.starts-with("$ ") {
          text(fill: c.termprompt, weight: "bold")[\$ ]
          text(fill: white, weight: "medium", it.text.slice(2))
        } else if it.number in cont {
          text(fill: white, weight: "medium", it.text)
        } else if it.text.starts-with("# ") {
          text(fill: c.faint, style: "italic", it.text)
        } else { it }
      }
      #raw(content, block: true)
    ]
  ]
}

// output: terminal block whose body is a captured file from book/output.
#let output(path, cmd: none, title: none, size: 7.2pt) = {
  let body = read("/book/output/" + path).trim(at: end)
  let full = if cmd != none { "$ " + cmd + "\n" + body } else { body }
  terminal(full, title: title, size: size)
}

// session: one terminal block made of several (command, captured file)
// steps. Use none for a step whose command printed nothing.
#let session(..steps, title: none) = {
  let parts = ()
  for (cmd, path) in steps.pos() {
    parts.push("$ " + cmd)
    if path != none {
      let b = read("/book/output/" + path).trim(at: end)
      if b != "" { parts.push(b) }
    }
  }
  terminal(parts.join("\n"), title: title)
}

// ---- Callouts --------------------------------------------------------------
#let _callout-kinds = (
  note: (c.note, "Note"),
  tip: (c.tip, "Tip"),
  warning: (c.warn, "Watch out"),
  production: (c.prod, "In production"),
  interview: (c.interview, "Interview lens"),
  internals: (c.internals, "Under the hood"),
  new: (c.new, "New in Go"),
)

#let callout(kind, body, title: none) = {
  let (accent, label) = _callout-kinds.at(kind)
  block(
    width: 100%, breakable: false, above: 1.2em, below: 1.2em,
    fill: accent.lighten(94%), stroke: (left: 2.6pt + accent),
    inset: (left: 13pt, right: 12pt, top: 9pt, bottom: 10pt), radius: (right: 4pt),
  )[
    #block(below: 6pt)[
      #text(font: fonts.sans, size: 7.4pt, weight: "bold", fill: accent, tracking: 0.08em)[#upper(label)]
      #if title != none {
        h(4pt); text(font: fonts.sans, size: 8.6pt, weight: "semibold", fill: c.ink)[#title]
      }
    ]
    #set text(size: 9.6pt)
    #set par(spacing: 0.8em)
    #body
  ]
}
#let note(body, title: none) = callout("note", body, title: title)
#let tip(body, title: none) = callout("tip", body, title: title)
#let warning(body, title: none) = callout("warning", body, title: title)
#let production(body, title: none) = callout("production", body, title: title)
#let interview(body, title: none) = callout("interview", body, title: title)
#let internals(body, title: none) = callout("internals", body, title: title)
#let newingo(version, body, title: none) = {
  let (accent, _) = _callout-kinds.new
  block(
    width: 100%, breakable: false, above: 1.2em, below: 1.2em,
    fill: accent.lighten(93%), stroke: (left: 2.6pt + accent),
    inset: (left: 13pt, right: 12pt, top: 9pt, bottom: 10pt), radius: (right: 4pt),
  )[
    #block(below: 6pt)[
      #box(fill: accent, radius: 2pt, inset: (x: 4pt, y: 2pt))[
        #text(font: fonts.sans, size: 7pt, weight: "bold", fill: white, tracking: 0.05em)[GO #version]
      ]
      #if title != none {
        h(5pt); text(font: fonts.sans, size: 8.6pt, weight: "semibold", fill: c.ink)[#title]
      }
    ]
    #set text(size: 9.6pt)
    #set par(spacing: 0.8em)
    #body
  ]
}

// ---- Figures & diagrams ------------------------------------------------------
#let fig(body, caption: none, placement: none) = figure(
  block(width: 100%, inset: (y: 6pt), align(center, body)),
  caption: caption,
  placement: placement,
  kind: image,
  supplement: [Figure],
)

// Shared fletcher styling so every diagram looks like part of one book.
#let dnode(pos, label, kind: "default", ..args) = {
  let styles = (
    default: (fill: white, stroke: 0.8pt + c.navy2),
    accent: (fill: c.go.lighten(85%), stroke: 0.8pt + c.godark),
    dark: (fill: c.navy, stroke: none),
    muted: (fill: c.codebg, stroke: 0.6pt + c.rule),
    warn: (fill: c.warn.lighten(88%), stroke: 0.8pt + c.warn),
    good: (fill: c.tip.lighten(88%), stroke: 0.8pt + c.tip),
  )
  let s = styles.at(kind)
  let lbl = if kind == "dark" { text(fill: white, label) } else { label }
  node(pos, text(font: fonts.sans, size: 7.6pt, lbl), corner-radius: 3pt,
    inset: 7pt, fill: s.fill, stroke: s.stroke, ..args)
}
#let dedge(..args) = {
  // Edge labels use the diagram's sans face, whatever the chapter passed.
  let named = args.named()
  if "label" in named {
    named.insert("label", text(font: fonts.sans, size: 6.6pt, fill: c.muted, named.label))
  }
  edge(stroke: 0.7pt + c.muted, ..args.pos(), ..named)
}

// ---- Inline helpers ----------------------------------------------------------
#let kbd(k) = box(
  inset: (x: 3pt, y: 1.5pt), outset: (y: 1.5pt), radius: 2pt,
  stroke: 0.5pt + c.faint, fill: c.codebg,
  text(font: fonts.mono, size: 0.82em, k),
)
#let term(t) = text(weight: "semibold", t) // a defined term, first use

// Key takeaways / exercises blocks at chapter end
#let takeaways(..items) = block(
  width: 100%, above: 1.4em, below: 1.4em, inset: 14pt, radius: 5pt,
  fill: c.navy, breakable: true,
)[
  #text(font: fonts.sans, size: 8pt, weight: "bold", fill: c.go, tracking: 0.1em)[KEY TAKEAWAYS]
  #v(4pt)
  #set text(fill: rgb("#e6edf5"), size: 9.6pt)
  #show raw.where(block: false): it => text(font: fonts.mono, size: 0.86em, fill: c.go.lighten(35%), it.text)
  #set list(marker: text(fill: c.go)[▸], spacing: 0.75em)
  #for it in items.pos() [- #it]
]

#let exercises(..items) = {
  heading(level: 2, numbering: none, outlined: true)[Exercises]
  set enum(numbering: n => text(font: fonts.sans, weight: "bold", fill: c.godark)[#n.], spacing: 1em)
  for (i, it) in items.pos().enumerate() [+ #it]
}

// ---- Chapter & part openers -----------------------------------------------------
#let chapter-meta = state("chapter-meta", none)

#let chapter(number, title, label: none, abstract: none, learn: (), build: none) = {
  pagebreak(weak: true)
  counter(heading).update(number - 1)
  counter(figure.where(kind: image)).update(0)
  counter(figure.where(kind: table)).update(0)
  [#heading(level: 1, title) #if label != none { label }]
  if abstract != none {
    v(2pt)
    block(width: 92%)[
      #set text(size: 11.6pt, style: "italic", fill: c.muted)
      #set par(leading: 0.7em)
      #abstract
    ]
  }
  if learn.len() > 0 or build != none {
    v(10pt)
    grid(
      columns: if build != none { (1.35fr, 1fr) } else { (1fr,) },
      column-gutter: 12pt,
      block(width: 100%, inset: 12pt, radius: 5pt, stroke: 0.6pt + c.rule, fill: c.codebg)[
        #text(font: fonts.sans, size: 7.4pt, weight: "bold", fill: c.godark, tracking: 0.1em)[WHAT YOU'LL LEARN]
        #v(2pt)
        #set text(size: 9.2pt)
        #set list(marker: text(fill: c.go)[▸], spacing: 0.6em)
        #for l in learn [- #l]
      ],
      ..if build != none {
        (block(width: 100%, inset: 12pt, radius: 5pt, fill: c.navy)[
          #text(font: fonts.sans, size: 7.4pt, weight: "bold", fill: c.go, tracking: 0.1em)[WHAT YOU'LL BUILD]
          #v(2pt)
          #set text(size: 9.2pt, fill: rgb("#e6edf5"))
          #show raw.where(block: false): it => text(font: fonts.mono, size: 0.86em, fill: c.go.lighten(35%), it.text)
          #build
        ],)
      },
    )
  }
  v(6pt)
}

#let part(numeral, title, blurb: none) = {
  pagebreak(weak: true)
  page(fill: c.navy, header: none, footer: none, margin: (x: 0.9in, y: 1in))[
    #metadata((kind: "part", numeral: numeral, title: title)) <part-marker>
    #v(1fr)
    #text(font: fonts.sans, size: 11pt, weight: "bold", fill: c.go, tracking: 0.25em)[PART #numeral]
    #v(6pt)
    #block(width: 100%, {
      set par(justify: false)
      text(font: fonts.sans, size: 30pt, weight: "bold", fill: white, hyphenate: false)[#title]
    })
    #v(10pt)
    #line(length: 50pt, stroke: 3pt + c.go)
    #if blurb != none {
      v(14pt)
      block(width: 85%, text(size: 11.5pt, fill: rgb("#b8c4d4"), style: "italic", blurb))
    }
    #v(1.4fr)
  ]
}

// ---- Cover -----------------------------------------------------------------------
#let cover() = page(margin: 0pt, fill: c.navy, header: none, footer: none)[
  // A deterministic "cluster topology": nodes on a jittered grid, edges to near
  // neighbours. Pure Typst, so the cover is vector and reproducible.
  #let W = 7.5in
  #let H = 9.25in
  #let pts = ()
  #let seed = 7
  #for row in range(9) {
    for col in range(7) {
      seed = calc.rem(seed * 1103515245 + 12345, 2147483648)
      let jx = calc.rem(seed, 1000) / 1000.0
      seed = calc.rem(seed * 1103515245 + 12345, 2147483648)
      let jy = calc.rem(seed, 1000) / 1000.0
      pts.push((col * 1.25in + jx * 0.9in - 0.2in, row * 1.12in + jy * 0.8in - 0.2in, calc.rem(seed, 7)))
    }
  }
  #for (i, a) in pts.enumerate() {
    for b in pts.slice(i + 1) {
      let dx = (a.at(0) - b.at(0)) / 1in
      let dy = (a.at(1) - b.at(1)) / 1in
      let d = calc.sqrt(dx * dx + dy * dy)
      if d < 1.45 {
        place(top + left, line(start: (a.at(0), a.at(1)), end: (b.at(0), b.at(1)),
          stroke: 0.5pt + c.go.transparentize(if a.at(2) == 0 { 40% } else { 82% })))
      }
    }
  }
  #for p in pts {
    let r = if p.at(2) == 0 { 4.5pt } else if p.at(2) < 3 { 2.6pt } else { 1.6pt }
    let f = if p.at(2) == 0 { c.go } else { c.go.transparentize(55%) }
    place(top + left, dx: p.at(0) - r, dy: p.at(1) - r, circle(radius: r, fill: f))
  }
  // Gradient veil so the title block reads cleanly.
  #place(top + left, rect(width: W, height: H, fill: gradient.linear(
    (c.navy.transparentize(100%), 0%), (c.navy.transparentize(35%), 45%), (c.navy, 72%), (c.navy, 100%), angle: 90deg)))
  #place(bottom + left, dx: 0.75in, dy: -0.85in, block(width: 6in)[
    #text(font: fonts.sans, size: 9.5pt, weight: "bold", fill: c.go, tracking: 0.3em)[GO 1.27 EDITION]
    #v(10pt)
    #text(font: fonts.sans, size: 58pt, weight: "black", fill: white, tracking: -0.02em)[Platform]
    #v(-30pt)
    #text(font: fonts.sans, size: 58pt, weight: "black", fill: c.go, tracking: -0.02em)[Go]
    #v(6pt)
    #line(length: 60pt, stroke: 3pt + c.go)
    #v(10pt)
    #block(width: 5.3in, text(font: fonts.sans, size: 13.5pt, weight: "medium", fill: rgb("#d8e1ec"))[
      Production-grade tools, operators, services, and AI systems for platform engineering
    ])
    #v(18pt)
    #text(font: fonts.sans, size: 9pt, fill: rgb("#8fa3bb"), tracking: 0.04em)[
      CLIs #h(3pt)·#h(3pt) Operators #h(3pt)·#h(3pt) gRPC #h(3pt)·#h(3pt) Observability #h(3pt)·#h(3pt) GitOps #h(3pt)·#h(3pt) Multi-cloud #h(3pt)·#h(3pt) AI & MCP
    ]
    #v(26pt)
    #text(font: fonts.sans, size: 12pt, weight: "semibold", fill: white)[#book-author]
  ])
]

// ---- The book show rule -----------------------------------------------------------
#let book(body) = {
  set document(title: book-title + ": " + book-subtitle, author: book-author,
    keywords: ("Go", "platform engineering", "DevOps", "Kubernetes", "operators", "CLI", "MCP"))

  set page(
    width: 7.5in, height: 9.25in,
    margin: (x: 0.78in, top: 0.92in, bottom: 0.9in),
    header: context {
      let p = here().page()
      let openers = query(heading.where(level: 1)).filter(h => h.location().page() == p)
      if openers.len() > 0 { return }
      let chs = query(heading.where(level: 1).before(here()))
      if chs.len() == 0 { return }
      let ch = chs.last()
      let secs = query(heading.where(level: 2).before(here()))
        .filter(h => h.location().page() <= p and h.location().position().y > 0pt)
      let on-page = query(heading.where(level: 2)).filter(h => h.location().page() == p)
      let sec = if on-page.len() > 0 { on-page.first() } else if secs.len() > 0 { secs.last() } else { none }
      if sec != none and sec.location().page() > p { sec = none }
      set text(font: fonts.sans, size: 7.4pt, fill: c.faint)
      let num = if ch.numbering != none { numbering("1", ..counter(heading).at(ch.location()).slice(0, 1)) } else { none }
      grid(columns: (1fr, auto),
        [#if num != none [#text(weight: "bold", fill: c.godark)[#num] #h(5pt)] #ch.body],
        [#if sec != none and chs.last().location().page() <= sec.location().page() { sec.body }],
      )
      v(-4pt)
      line(length: 100%, stroke: 0.4pt + c.rule)
    },
    footer: context {
      set text(font: fonts.sans, size: 7.8pt, fill: c.muted)
      align(center, counter(page).display())
    },
  )

  set text(font: fonts.serif, size: 10.4pt, fill: c.ink, lang: "en", hyphenate: true,
    number-type: "lining")
  set par(justify: true, leading: 0.68em, spacing: 1.05em)
  show link: set text(fill: c.godark)
  set list(marker: ([•], [–]), indent: 4pt, body-indent: 6pt, spacing: 0.75em)
  set enum(indent: 4pt, body-indent: 6pt, spacing: 0.75em)

  // Inline code
  show raw.where(block: false): it => box(
    fill: c.codebg, inset: (x: 1.8pt), outset: (y: 2.2pt), radius: 2pt,
    text(font: fonts.mono, size: 0.84em, fill: rgb("#24292f"), it),
  )
  // Block code (inside listing() frames)
  show raw: set text(ligatures: false, features: (calt: 0), hyphenate: false)
  show raw.where(block: true): set text(font: fonts.mono, size: 7.9pt)
  show raw.where(block: true): set par(justify: false, leading: 0.52em)
  set raw(tab-size: 4, theme: "/book/template/platform-light.tmTheme")

  // Headings
  set heading(numbering: (..n) => {
    let n = n.pos()
    if n.len() == 1 { str(n.at(0)) } else { n.map(str).join(".") }
  })
  show heading: set text(font: fonts.sans, fill: c.navy, hyphenate: false)
  show heading: set par(justify: false)
  show heading.where(level: 1): it => {
    block(width: 100%, above: 0pt, below: 14pt)[
      #v(0.35in)
      #if it.numbering != none {
        text(font: fonts.sans, size: 10pt, weight: "bold", fill: c.go, tracking: 0.25em)[CHAPTER #counter(heading).display("1")]
        v(4pt)
      }
      #text(size: 25pt, weight: "bold", tracking: -0.01em)[#it.body]
      #v(8pt)
      #line(length: 46pt, stroke: 3pt + c.go)
    ]
  }
  show heading.where(level: 2): it => {
    block(above: 2em, below: 1em, sticky: true)[
      #set text(size: 14pt, weight: "bold")
      #if it.numbering != none {
        text(fill: c.go)[#counter(heading).display()]
        h(8pt)
      }
      #it.body
    ]
  }
  show heading.where(level: 3): it => block(above: 1.6em, below: 0.8em, sticky: true,
    text(size: 11pt, weight: "semibold", fill: c.navy2, it.body))
  show heading.where(level: 4): it => block(above: 1.3em, below: 0.7em, sticky: true,
    text(size: 9.8pt, weight: "semibold", fill: c.muted, it.body))

  // Figures and tables
  show figure.caption: it => {
    set text(font: fonts.sans, size: 8pt, fill: c.muted)
    [#text(weight: "bold", fill: c.navy2)[#it.supplement #context it.counter.display(it.numbering)] #h(3pt) #it.body]
  }
  set figure(numbering: n => {
    let ch = counter(heading).get().first()
    str(ch) + "." + str(n)
  })
  set table(stroke: none, inset: (x: 7pt, y: 5.5pt))
  show table: set text(size: 8.8pt, hyphenate: false)
  show table: set par(justify: false, leading: 0.6em)
  show table.cell.where(y: 0): set text(font: fonts.sans, weight: "bold", size: 8pt, fill: c.navy)
  set table(fill: (_, y) => if y == 0 { c.codehead } else if calc.even(y) { c.codebg } else { none })

  // Emphasis tweaks
  show strong: set text(weight: "semibold")
  show "Go 1.27": it => it

  body
}
