// Platform Go: the book. Build from the repository root:
//   typst compile --root . --font-path book/fonts book/main.typ platform-go.pdf
#import "template/book.typ": *
#show: book

#cover()
#counter(page).update(1)
#set page(numbering: "i")
#include "frontmatter/front.typ"
#include "frontmatter/preface.typ"

#set page(numbering: "1")
#counter(page).update(1)

#part("I", "Foundations: Go for Systems Work",
  blurb: [The language and runtime from a platform engineer's point of view: what makes Go the default for infrastructure, and the disciplines that keep tools correct under concurrency, failure, and change.])
#include "chapters/00-zero.typ"
#include "chapters/01-toolchain.typ"
#include "chapters/02-api-design.typ"
#include "chapters/03-errors.typ"
#include "chapters/04a-concurrency.typ"
#include "chapters/04b-concurrency.typ"
#include "chapters/04c-concurrency.typ"
#include "chapters/05-os.typ"
#include "chapters/06-testing.typ"

#part("IV", "Kubernetes and the Cloud",
  blurb: [Programming the platforms themselves: cloud SDKs without lock-in, the Kubernetes API from first principles, and operators built to production standards.])
#include "chapters/20-operators.typ"

#include "appendix/d-solutions.typ"
