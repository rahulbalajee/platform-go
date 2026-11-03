#import "../template/book.typ": *

// Chapter 4's short name for the template's quote-output: a troubleshooting
// row quotes the first lines of a real failure that
// book/scripts/capture-ch04.sh produced by breaking a copy of a build step.
#let ts(name) = quote-output("ch04/ts/" + name)
