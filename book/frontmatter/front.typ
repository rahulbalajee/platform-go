#import "../template/book.typ": *
#import "../plan.typ": plan, appendices

// ---- Title page ----------------------------------------------------------------
#page(header: none, footer: none, margin: (x: 0.9in, y: 1.1in))[
  #v(1.2in)
  #text(font: fonts.sans, size: 10pt, weight: "bold", fill: c.go, tracking: 0.3em)[GO 1.27 EDITION]
  #v(8pt)
  #text(font: fonts.sans, size: 40pt, weight: "black", fill: c.navy)[Platform Go]
  #v(4pt)
  #line(length: 60pt, stroke: 3pt + c.go)
  #v(10pt)
  #block(width: 85%, text(font: fonts.sans, size: 14pt, fill: c.muted)[#book-subtitle])
  #v(1fr)
  #text(font: fonts.sans, size: 13pt, weight: "semibold", fill: c.ink)[#book-author]
  #v(4pt)
  #text(font: fonts.sans, size: 9pt, fill: c.faint)[Review draft · checkpoint 1 · November 2026]
]

// ---- Copyright / colophon -------------------------------------------------------------
#page(header: none, footer: none)[
  #v(1fr)
  #set text(size: 8.6pt, fill: c.muted)
  #set par(justify: false, spacing: 0.9em)
  *Platform Go: #book-subtitle* \
  Go 1.27 edition. Review draft, checkpoint 1 (November 2026).

  Copyright © 2026 #book-author. All rights reserved. The source code in the
  companion repository is licensed under the Apache License 2.0; the text of
  this book is not.

  Companion repository: #raw(repo-url). Every listing in this book is
  extracted at build time from files in that repository, which compile and
  pass `go vet`, `golangci-lint` and `go test -race` in CI. Terminal output
  was captured from real runs, unless a block is marked as an excerpt.

  #table(
    columns: (auto, auto),
    stroke: none, inset: (x: 0pt, y: 2.5pt), fill: none,
    [Go], [1.27.3],
    [Kubernetes APIs], [1.37 (`k8s.io/*` v0.37.2); e2e on kind with Kubernetes 1.36],
    [controller-runtime / kubebuilder], [v0.25.2 / v4.16.0],
    [golangci-lint], [v2.15.0],
    [Typeset with], [Typst 0.15 · Source Serif 4, Inter, JetBrains Mono],
  )

  The author and publisher have made every effort to ensure the accuracy of
  the information in this book. Version-specific behaviour is called out
  with a #box(fill: c.go, radius: 2pt, inset: (x: 3pt, y: 1.5pt))[#text(font: fonts.sans, size: 6.5pt, weight: "bold", fill: white)[GO 1.xx]]
  badge so you can tell what requires a recent toolchain.
  #v(0.4in)
]

// ---- Contents -------------------------------------------------------------------------
#let toc-line(num, title, target) = {
  set text(size: 9.4pt)
  grid(
    columns: (22pt, 1fr, auto),
    column-gutter: 4pt,
    text(font: fonts.sans, weight: "bold", fill: if target != none { c.godark } else { c.faint })[#num],
    if target != none {
      link(target)[#text(fill: c.ink)[#title] #box(width: 1fr, repeat[#text(fill: c.rule)[.]])]
    } else {
      text(fill: c.muted)[#title]
    },
    if target != none {
      context {
        let loc = locate(target)
        let fmt = if loc.page-numbering() != none { loc.page-numbering() } else { "1" }
        text(font: fonts.sans, weight: "semibold", fill: c.navy)[#numbering(fmt, ..counter(page).at(loc))]
      }
    } else {
      text(font: fonts.sans, size: 7pt, fill: c.faint, tracking: 0.05em)[PLANNED]
    },
  )
}

#page(header: none)[
  #text(font: fonts.sans, size: 24pt, weight: "bold", fill: c.navy)[Contents]
  #v(2pt)
  #text(size: 9pt, fill: c.muted, style: "italic")[Chapters with page numbers are included in this review draft; the rest are planned.]
  #v(10pt)
  #toc-line([], [Preface], <preface>)
  #v(2pt)
  #toc-line([], [The skills map], <skills-map>)
  #for part in plan {
    // Keep each part heading together with its chapters.
    block(breakable: false, above: 9pt, below: 0pt, {
      text(font: fonts.sans, size: 7.6pt, weight: "bold", fill: c.go, tracking: 0.15em)[PART #part.numeral]
      h(6pt)
      text(font: fonts.sans, size: 8.6pt, weight: "bold", fill: c.navy)[#part.title]
      v(3pt)
      for (n, title, target, _) in part.chapters {
        toc-line(str(n), title, target)
        v(1.5pt)
      }
    })
  }
  #v(9pt)
  #text(font: fonts.sans, size: 7.6pt, weight: "bold", fill: c.go, tracking: 0.15em)[APPENDICES]
  #v(3pt)
  #for (l, title) in appendices {
    toc-line(l, title, none)
    v(1.5pt)
  }
]

// ---- Detailed contents of the included chapters ---------------------------------------------
#page(header: none)[
  #text(font: fonts.sans, size: 16pt, weight: "bold", fill: c.navy)[In this draft]
  #v(6pt)
  #set text(size: 9pt)
  #outline(title: none, depth: 2, indent: 14pt)
]
