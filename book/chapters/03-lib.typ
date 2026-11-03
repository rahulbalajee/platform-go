#import "../template/book.typ": *

// Chapter 3's short name for the template's quote-output: a troubleshooting
// row quotes the first lines of a real failure that
// book/scripts/capture-ch03.sh produced by breaking a copy of a build step.
#let ts(name) = quote-output("ch03/ts/" + name)
