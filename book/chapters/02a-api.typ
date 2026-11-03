#import "../template/book.typ": *
#import "02-lib.typ": ts, needspace

#step(1, 8, "Types and a first call", label: <sec-api-s1>)

The first version is the smallest SDK that works end to end: three resource
types, a `Client` that fetches one environment, service or deployment over
HTTP, a fake platform to fetch them from, and tests that tie the two
together. Every later step changes these files; none replaces them.

Start with an empty module:

#session(
  ("mkdir platformapi && cd platformapi", none),
  ("go mod init platformapi", "ch02/s1-modinit.txt"),
  ("go get go@1.27.0", "ch02/s1-goget.txt"),
)

`go mod init` writes the exact toolchain version you ran into the `go` line
of `go.mod`, and `go get go@1.27.0` lowers it to the first 1.27 release.
That line is the _minimum_ Go version for everyone who imports the module,
which makes it part of a library's API (the lab comes back to this). A real
SDK would have a path such as `github.com/acme/platformapi`, so that other
modules can fetch it; the short path `platformapi` keeps the listings
narrow. Packages inside the module are imported as `platformapi/...`.

=== Resource types

The API serves three kinds of resource. Create `types.go`:

#src("workbook/ch02/step1/types.go", region: "resources")

The backquoted text after each field is a _struct tag_. `encoding/json`
reads it to map the Go field `CreatedAt` to the JSON key `created_at`, so
the SDK can follow Go's naming conventions while the wire format follows
the API's. Chapter 0 introduced tags; the rule to remember here is that the
tag, not the field name, is what the server sees, and a typo in one is
invisible to the compiler.

A deployment moves through a lifecycle. Add its state type to the same
file:

#src("workbook/ch02/step1/types.go", region: "state")

`DeploymentState` is a `string` with a name of its own, so a function that
wants a state can't be handed an arbitrary string by accident, and the
constants give every known value a name. The doc comment makes a promise
that matters more than it looks: new states may be added, and unknown
values mean "not finished". A `switch` written against today's five states
still behaves when the server adds `paused` next year, because the caller
was told to treat anything unexpected as still running. `Done` is a method
on the state type, so callers write `d.State.Done()` instead of repeating
the three terminal states in every program.

Finally, the deployment itself:

#src("workbook/ch02/step1/types.go", region: "deployment")

`omitempty` leaves `reason` out of the JSON when it is empty. Every type in
this file is plain data with exported fields: callers build them, compare
them and print them, and a struct can gain fields later without breaking
callers who use field names in their literals (the lab shows the one way it
can still break).

=== The client

Create `client.go`:

#src("workbook/ch02/step1/client.go", region: "client")

`New` returns a `*Client`, a pointer to a struct whose fields are all
unexported. Callers can't reach `base` or `hc`; they can only call methods.
A tempting alternative, seen in many internal SDKs, exports an interface next
to its only implementation:

#code(file: "client.go", caption: "don't ship this")[```go
// Client is the platform API. Use New to get one.
type Client interface {
	CreateDeployment(ctx context.Context,
		req CreateDeploymentRequest) (*Operation, error)
	GetDeployment(ctx context.Context, id string) (*Deployment, error)
	// ... nine more methods
}

func New(baseURL string) Client { return &client{baseURL: baseURL} }
```]

It looks like good engineering, and it locks the SDK in place. The day the
platform team adds `DeploymentLogs`, every type that implements `Client`
stops compiling: every mock that 50 teams generated, every wrapper that adds
logging. Adding a method to a struct breaks nobody. Adding one to an
exported interface breaks everyone who implemented it. There are smaller
costs too. `go doc` shows one wall of method signatures instead of
documentation per method, and callers can't reach anything that isn't on
the interface. The proverb is _accept interfaces, return structs_; this is
its second half, and step 6 shows the first.

The doc comment says the zero value is not usable. Compare `http.Client`,
whose zero value works because nothing in it is required. A platform client
without a base URL can't do anything, and when a type's zero value can't be
made useful, the documentation says so and the constructor is the obvious
way in. `New` validates its one argument with a helper. Add it below `New`:

#src("workbook/ch02/step1/client.go", region: "parse")

`New` performs no I/O: it doesn't ping the API or fetch anything. A
constructor that touches the network makes program startup depend on
another service being up, makes every test that builds a client slow or
flaky, and turns a configuration error and a network error into the same
failure. Errors from `New` are always configuration errors, and they always
happen before any work starts.

The `http.Client` has no `Timeout`, and the comment says why: deadlines come
from the caller's context, and a second, competing timeout would only produce
confusing errors.

#goconcept(title: [`context.Context`])[
  A `context.Context` carries a deadline, a cancellation signal, and a few
  request-scoped values across API boundaries. By convention it is the
  first parameter of anything that blocks or does I/O, named `ctx`. You
  never modify a context; you derive a child from it with
  `context.WithTimeout`, `WithDeadline` or `WithCancel`, and each returns a
  `cancel` function you must call, usually with `defer`. When a context is
  done, `ctx.Done()` is closed and `ctx.Err()` says why. Every method of the
  SDK takes one, and passes it to the HTTP request, so a caller who gives up
  stops the request too. In tests, `t.Context()` (Go 1.24) is cancelled when
  the test ends. Step 4 says more about contexts as part of an API.
]

=== Three ways to get a resource

#needspace(10em)
The methods live in their own file. Create `api.go`:

#src("workbook/ch02/step1/api.go", region: "api")

Each method validates its argument, asks a helper to fetch and decode the
JSON, and returns a pointer to the result. On error it returns `nil` and the
error, never a half-filled value, so a caller who checks `err` first can't be
fooled by a zero `Environment`. `checkID` rejects the three identifiers that
would change the meaning of a URL path. The names are short and say what
they get; the package name already says _from where_, because every call
site reads `client.GetEnvironment`, inside a program that imported
`platformapi`.

The helper, and the code that builds URLs, go in `transport.go`:

#src("workbook/ch02/step1/transport.go", region: "transport")

`getJSON` takes `out any`: a value of any type, which must be a pointer so
`Decode` can fill it. That is the convention of `json.Unmarshal` itself,
and it has a cost the compiler can't see. Pass `env` instead of `&env` and
the program compiles, runs, and fails with an error from deep inside
`encoding/json` (the checkpoint shows it). Step 4 replaces `getJSON` with a
generic helper that can't be called wrongly.

`url` escapes each path segment on its own, so an ID such as
`../environments/prod` becomes one segment, `..%2Fenvironments%2Fprod`, and
can't climb out of `/v1/deployments/`. Step 3 adds a test that proves it.
`drain` reads up to 64 KiB of an unused body before closing it, which lets
HTTP/1.1 reuse the connection.

#goconcept(title: [`http.Client` and response bodies])[
  `http.Client` sends requests and follows redirects; its `Transport` keeps a
  pool of open connections and reuses them. Create one client and share it,
  because a new client per request throws the pool away. A response's
  `Body` is a stream you must close, or the connection it holds is never
  returned to the pool; the `bodyclose` linter from Chapter 1 checks this for
  you. Status codes are data, not errors: a 404 or 503 comes back with
  `err == nil`, and only network-level failures (refused, reset, timed out)
  return an error. That is why `getJSON` checks `resp.StatusCode` itself.
]

=== A fake platform, and your first interface

The client needs a server to talk to, and tests should not need the real
platform. `platformapifake` is an in-memory platform that speaks the same
HTTP API. To be served by Go's HTTP server, it has to be an `http.Handler`,
and that is the first interface you implement in this chapter.

#goconcept(title: [Interfaces])[
  An interface type is a list of method signatures. It describes what a
  value can _do_, not what it _is_. Here is the most used interface in
  `net/http`:

  #code(file: "net/http (standard library)")[```go
  type Handler interface {
  	ServeHTTP(ResponseWriter, *Request)
  }
  ```]

  Any type that has a method `ServeHTTP` with exactly that signature
  _satisfies_ `http.Handler`. Nothing in the type says so. There is no
  `implements` keyword; having the method is enough, and the compiler checks
  it wherever the type is used as a `Handler`:

  #code(file: "sketch")[```go
  type hello struct{}

  func (hello) ServeHTTP(w http.ResponseWriter, r *http.Request) {
  	fmt.Fprintln(w, "hello")
  }

  var h http.Handler = hello{} // compiles: hello has ServeHTTP
  http.ListenAndServe(":8080", h)
  ```]

  An _interface value_ such as `h` holds two things: a concrete value and
  its type. Calling `h.ServeHTTP(w, r)` calls the method of whatever type is
  inside. The zero value of an interface is `nil`, holding neither, and
  calling a method on it panics.

  Because satisfaction is implicit, an interface can be declared _after_ the
  types that satisfy it, in a different package, by someone who has never
  met their authors. `net/http` doesn't know `platformapifake` exists, yet
  `http.ListenAndServe` and `httptest.NewServer` accept a `*Server`. This one
  rule shapes how Go code is designed: interfaces are small (one or two
  methods), and they are usually declared by the code that _uses_ them.
  _Coming from Java or C\#:_ the same idea without the declaration.
  _Coming from Python:_ duck typing, checked at compile time.
]

Make a directory `platformapifake` and create `platformapifake/fake.go`:

#src("workbook/ch02/step1/platformapifake/fake.go", region: "fake")

`Server` has a method `ServeHTTP(http.ResponseWriter, *http.Request)`, so
`*Server` is an `http.Handler`. It hands every request to an
`http.ServeMux`, which is itself a handler that routes by method and path.
Since Go 1.22 a pattern such as `"GET /v1/environments/{name}"` matches only
`GET` requests, and the handler reads the wildcard with
`r.PathValue("name")`. `writeError` sends the API's error body,
`{"error": {"code": ..., "message": ...}}`, which step 3 teaches the client
to read.

The HTTP server calls `ServeHTTP` on a new goroutine for every request, so
two requests can touch the fake's slices at the same time. The mutex `mu`
guards them: every handler locks it before reading or writing state and
unlocks it when done. Chapter 4 covers `sync.Mutex` properly; for now, the
rule is that the fields listed below `mu` are only touched while holding it.

#goconcept(title: [Method sets: pointer and value receivers])[
  A method declared as `func (s *Server) ServeHTTP(...)` has a _pointer
  receiver_: it belongs to the type `*Server`, and it can change the
  `Server` it points to. A method declared `func (s Server) ...` has a
  _value receiver_ and works on a copy. The _method set_ of `*Server`
  contains both kinds; the method set of `Server` contains only the
  value-receiver methods. So `*Server` satisfies `http.Handler` and a plain
  `Server` value does not, and the compiler says exactly that if you pass
  one (the checkpoint shows the message). Use pointer receivers when the
  method changes the value or the value holds a mutex, which must never be
  copied; use the same kind for every method of a type.
]

The fake keeps its own copies of the wire types. Create
`platformapifake/resources.go`:

#src("workbook/ch02/step1/platformapifake/resources.go", region: "types")

These look like duplicates of `types.go`, and that is the point. If the fake
imported the SDK's types, a wrong JSON tag in the SDK would be mirrored by
the fake, and every test would pass against a server that doesn't exist. With
its own types, the fake speaks the API's wire format, and the SDK has to get
it right.

The fake starts with three environments, five services and a history of
eight deployments. Add the seed below the types:

#src("workbook/ch02/step1/platformapifake/resources.go", region: "seed")

Then the three handlers and two lookup helpers:

#src("workbook/ch02/step1/platformapifake/resources.go", region: "get")

`New` returns a pointer, `*Server`, and every method has a pointer receiver,
so the mutex inside is never copied.

=== Tests

The SDK's tests live in the _external_ test package `platformapi_test`, in
the same directory. They import `platformapi` like any other user would, so
they can only use what is exported: if a test needs something private, a
real user would need it too. Create `client_test.go` with a helper that
starts the fake and builds a client for it:

#src("workbook/ch02/step1/client_test.go", region: "fixture")

`httptest.NewServer` starts a real HTTP server on a free local port, serving
any `http.Handler`, and `srv.URL` is its address. `t.Cleanup` registers
`srv.Close` to run when the test ends, so the helper can return without the
caller having to remember. `t.Helper` makes failures inside the helper
report the caller's line.

The first tests check the constructor:

#src("workbook/ch02/step1/client_test.go", region: "newtests")

`TestNewAcceptsBaseURLWithPathPrefix` covers a case that real deployments
hit: the API behind a gateway at `https://gateway.internal/api/`. The fake
is mounted under `/api/` with `http.StripPrefix`, another handler that wraps
a handler. Then the methods:

#src("workbook/ch02/step1/client_test.go", region: "gettests")

`TestGetDeploymentDecodesEveryField` compares the whole struct with `!=`,
which Go allows because every field of `Deployment` is comparable. It is the
test that catches a wrong JSON tag: the field it maps simply stays at its
zero value.

#needspace(12em)
#checkpoint(step: 1, of: 8, title: [Types and a first call])[
  Your module should contain these Go files:
  #output("ch02/s1-tree.txt", cmd: "find . -name '*.go' | sort")
  Vet and test it:
  #output("ch02/s1-test.txt", cmd: "go vet ./... && go test ./...")
  The fake has no tests of its own yet; the SDK's tests exercise it. Ask
  for the names of the tests that ran:
  #output("ch02/s1-testv.txt", cmd: "go test -v -run 'TestGet|TestMissing' .")
  And look at the API you have built, as its users will see it:
  #output("ch02/s1-doc.txt", cmd: "go doc .")
  `go doc` lists exported names only, grouped under their types: `New`
  appears under `Client` because it returns one. Everything else in the
  package is invisible, which is what lets you change it.
  #troubleshoot(
    ([#ts("s1-nonpointer.txt")], [`getJSON` was given `env` instead of `&env`. `Decode` needs a pointer to fill in, and `out any` lets anything through.], [Pass a pointer. Step 4 removes the trap.]),
    ([#ts("s1-tag.txt")], [The struct printed below that line has a zero field: a JSON tag doesn't match the server's key (here `updatedReplicas` for `updated_replicas`).], [Copy tags from the API's documentation; see "Resource types".]),
    ([#ts("s1-handler.txt")], [A `Server` value was passed where an `http.Handler` is needed. Only `*Server` has `ServeHTTP`.], [Pass the pointer `New` returns. See "Method sets".]),
    ([#ts("s1-modpath.txt")], [The module path in `go.mod` is not `platformapi`, so the import `platformapi` matches nothing and Go looks in the standard library.], [Make the `module` line and the import paths agree.]),
    ([#ts("s1-bodyclose.txt")], [`defer drain(resp)` is missing, so every call leaks a connection.], [Drain and close every body you are done with.]),
  )
]

#step(2, 8, "Options and the interfaces the SDK consumes", label: <sec-api-s2>)

A client has one required setting, where the API is, and a long tail of
optional ones that will keep growing for as long as the SDK exists: the
HTTP client, credentials, a product name for the User-Agent, a logger, a
rate limit. This step gives `New` a way to take them without ever changing
its signature again, and introduces the two interfaces the SDK _consumes_.

=== Three shapes for configuration

Go code uses three shapes for configuration, and each has a place:

#table(
  columns: (auto, 1fr, 1fr),
  align: (left, left, left),
  table.header([Shape], [Good at], [Weak at]),
  [Config struct\ `retry.Policy{MaxAttempts: 4}`], [Visible: callers see every setting in one place and can print, compare and copy it. Easy to fill from YAML or flags. With care, the zero value means "defaults".], [It can't tell "unset" from "zero". Adding a field whose default isn't zero needs a pointer or a sentinel. Validation is a separate step that callers can skip. Required and optional fields look the same.],
  [Functional options\ `New(url, WithToken(t))`], [Defaults stay internal and can change. Each option validates its own input. Required arguments stay positional. New options never break existing calls.], [More code per setting. You can't inspect a built configuration. Discovery depends on good docs (`go doc` groups the options under `Option`, which helps).],
  [Builder\ `NewBuilder().Token(t).Build()`], [Familiar to Java and C\# developers.], [Errors pile up until `Build` or get lost mid-chain, a half-built builder can be shared by accident, and it reads as foreign in Go code.],
)

`platformapi` takes the base URL as a positional argument and everything
else as functional options.

#goconcept(title: [Closures and functional options])[
  A function literal can use variables from the function around it, and it
  keeps them alive for as long as the literal exists:

  #code(file: "sketch")[```go
  func WithToken(token string) Option {
  	return func(c *config) error { // captures token
  		c.tokens = StaticToken(token)
  		return nil
  	}
  }
  ```]

  `WithToken("abc")` returns a function that remembers `"abc"` and, when
  `New` calls it later, stores it in the configuration being built. That
  returned function is a _closure_, and an `Option` is nothing more than a
  closure with a known signature. `New(url, opts ...Option)` is _variadic_:
  callers pass zero or more options, and inside `New` the parameter `opts`
  is a slice. JavaScript closures behave the same way; Python's are similar
  but can't rebind captured names without `nonlocal`.
]

Replace the top of `client.go`, from the package clause down to the end of
the `Client` type, with:

#src("workbook/ch02/step2/client.go", region: "imports")
#src("workbook/ch02/step2/client.go", region: "client")

`Client` no longer lists its HTTP client directly. It _embeds_ a `config`
struct, and every setting an option can change lives there.

#goconcept(title: [Struct embedding])[
  A struct field with a type but no name is _embedded_. Its fields and
  methods are _promoted_: `c.hc` works on a `Client` even though `hc` is
  declared in `config`, because the compiler rewrites it to `c.config.hc`.
  That is why `getJSON` in `transport.go` keeps compiling when `hc` moves
  into `config`. Embedding is composition, not inheritance: a `Client` is
  not a `config`, you can't pass one where the other is expected, and the
  embedded struct's methods still receive the inner value. Embedding a
  type also promotes its methods, which step 6 uses to adapt one type to an
  interface.
]

Replace `New` with the `Option` type and a constructor that applies options:

#src("workbook/ch02/step2/client.go", region: "option")

Several decisions in those lines are deliberate.

*The `Option` type takes an unexported `*config`, not `*Client`.* An early
draft used `type Option func(*Client) error`. That compiles fine, and it
means a caller can write `platformapi.WithLogger(l)(client)` to reconfigure
a live client that other goroutines are using, a data race the SDK would be
blamed for. With an unexported parameter type, callers can neither write
their own options nor apply one after `New` returns (the checkpoint shows
the compiler refusing). The set of options is closed, and a built `Client`
is immutable.

*`New` validates everything and reports everything.* Each option checks its
input, and `New` joins every error with `errors.Join`, so a misconfigured
client produces one message listing all of its problems, not one problem
per deploy attempt. The defaults are set before the options run, so an
option only has to say what differs.

*The defaults are production defaults.* Logs are discarded unless the caller
asks for them (`slog.DiscardHandler` is a handler that drops everything), and
step 7 adds retries that are on by default, because a caller who forgets
to configure them should get safe behaviour, not fragile behaviour.

`parseBaseURL` stays as it was. Below it, add the first two options. Each
is a constructor for a closure that validates and stores one setting:

#src("workbook/ch02/step2/client.go", region: "options")

`WithHTTPClient` is the SDK's hook for everything it doesn't do itself: TLS
settings, proxies, and tracing. A caller who wraps the transport with
OpenTelemetry's instrumented `RoundTripper` (Chapter 17) gets a span for
every request without the SDK importing a tracing library.

`WithUserAgent` deserves attention beyond its few lines. It doesn't replace
the User-Agent, it prefixes it, so every request says something like
`ship/2.3.0 platformapi-go/1.0.0`. When the platform team wants to remove a
deprecated endpoint, the server's access logs say which products and which
SDK versions still call it. That is the cheapest observability an SDK can
have, and it only works if callers can't turn it off. The `\r\n` check stops
a product name from smuggling a second header into the request.

=== Interfaces the SDK consumes

The SDK _uses_ two behaviours that callers supply, so the SDK declares those
interfaces. The first is a source of bearer tokens. Create `token.go`:

#src("workbook/ch02/step2/token.go", region: "token")

`Token` takes a context because fetching a token can mean a network call to
an identity provider, and that call must respect the caller's deadline.
This is easy to get wrong, and once it ships it can't be fixed.
`golang.org/x/oauth2` defines its `TokenSource` as `Token() (*Token, error)`
with no context. Its refreshing implementation therefore keeps a context in
a struct field, captured when the source was built (the field is commented
`// used to get HTTP requests` in `oauth2.go`). Adding a context parameter
now would break every `TokenSource` implementation in the ecosystem, so the
interface stays as it is. If a method might ever do I/O, give it a context
from the first release.

#goconcept(title: [Function types with methods])[
  Any named type can have methods, including a function type.
  `TokenSourceFunc` is a function type with a `Token` method that calls the
  function itself, so an ordinary function becomes a `TokenSource` by
  conversion: `TokenSourceFunc(myFunc)`. The standard library's
  `http.HandlerFunc` is the same trick for `http.Handler`. Without it, every
  one-method implementation would need a named struct type. The conversion
  is required: a plain `func(context.Context) (string, error)` has no
  methods, so it doesn't satisfy the interface, and the checkpoint shows
  the compiler saying so. `StaticToken` uses the adapter itself, and returns
  the interface because the caller only needs the behaviour.
]

The options that install a token source go below `WithUserAgent`:

#src("workbook/ch02/step2/client.go", region: "tokenoptions")

then the logger:

#src("workbook/ch02/step2/client.go", region: "logger")

The second behaviour is client-side rate limiting, at the end of the file:

#src("workbook/ch02/step2/client.go", region: "limiter")

`*rate.Limiter` from `golang.org/x/time/rate` has a method
`Wait(ctx context.Context) error`, so it satisfies `Limiter` without either
package knowing about the other. The SDK gets rate limiting without adding
`x/time` to its dependencies, and its API doesn't mention a third-party type
whose version would then be tied to the SDK's own. The tests prove it by
handing the client a real `*rate.Limiter`.

=== When an exported interface is a mistake

`TokenSource` and `Limiter` are exported interfaces, and step 1 argued
against exporting `Client` as one. The difference is direction. An
interface in a library is a mistake when it has one implementation and
exists "so callers can mock it". It is a mistake when it is large, because
every method is something every implementer must write and nobody can add
to it. And it is a mistake when it describes the library's own behaviour
rather than something the library needs from the outside. `TokenSource` and
`Limiter` pass that test: one method each, implemented by callers, consumed
by the SDK.

=== Using the settings

`getJSON` now sends the User-Agent and the token, waits for the limiter,
and logs each request. Replace the import block of `transport.go`:

#src("workbook/ch02/step2/transport.go", region: "imports")

and replace `getJSON`:

#src("workbook/ch02/step2/transport.go", region: "getjson")

The limiter is consulted _before_ the request is built, and a limiter that
gives up (because the context ended) ends the call. `LogAttrs` with typed
attributes is the allocation-free way to log with `slog`; at the default
discard level it costs almost nothing.

=== The fake learns to check tokens

The fake needs two knobs for tests: a token it insists on, and a record of
what it received. Replace the top of `platformapifake/fake.go`, from the
package comment to the end of the import block:

#src("workbook/ch02/step2/platformapifake/fake.go", region: "imports")

Replace the `Server` type, and add the `Request` type above it:

#src("workbook/ch02/step2/platformapifake/fake.go", region: "server")

`New` and `routes` stay as they were. Replace `ServeHTTP` with these three
methods:

#src("workbook/ch02/step2/platformapifake/fake.go", region: "knobs")

`ServeHTTP` now records every request, answers 401 if a token is required
and missing, and echoes an `X-Request-Id` (generating one if the client
sent none) the way real platforms do. `Requests` returns a copy made with
`slices.Clone`, so a test can't change the fake's state through it, and the
copy is taken while holding the lock.

=== Tests

The fixture now requires a token and passes it, along with the User-Agent
and the HTTP client of the test server. Replace the import block and
`newClient` in `client_test.go`:

#src("workbook/ch02/step2/client_test.go", region: "fixture")

`opts` are appended after the defaults, so a test that passes
`WithToken("stale-token")` overrides the good one: the same "later option
wins" rule `New` documents. The test that proves `*rate.Limiter` is a
`Limiter` needs the module, so add it:

#session(
  ("go get golang.org/x/time@v0.16.0", "ch02/s2-goget.txt"),
  ("go mod tidy", "ch02/s2-tidy.txt"),
)

Create `options_test.go`:

#src("workbook/ch02/step2/options_test.go", region: "head")

`TestNewReportsEveryProblem` passes four bad settings and checks that the
one error names all four. Then identification and tokens:

#src("workbook/ch02/step2/options_test.go", region: "identified")

`TestTokenSourceErrorStopsTheCall` uses `TokenSourceFunc` to turn a closure
into a token source in one line, and checks that no request went out
without a token. Last, the limiter:

#src("workbook/ch02/step2/options_test.go", region: "limiter")

`countingLimiter` is the smallest possible `Limiter`: a struct with one
method. `var _ platformapi.Limiter = (*rate.Limiter)(nil)` is a
compile-time assertion, a common Go idiom: it declares a throwaway variable
of the interface type and assigns a typed nil pointer to it, so the build
fails if `*rate.Limiter` ever stops satisfying `Limiter`. It costs nothing
at run time.

The fake gets a test of its own. Create `platformapifake/fake_test.go`:

#src("workbook/ch02/step2/platformapifake/fake_test.go", region: "faketest")

#needspace(12em)
#checkpoint(step: 2, of: 8, title: [Options and the interfaces the SDK consumes])[
  #output("ch02/s2-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch02/s2-test.txt", cmd: "go vet ./... && go test ./...")
  One misconfigured `New`, one error, four problems:
  #output("ch02/s2-every.txt", cmd: "go test -v -run TestNewReportsEveryProblem . | fold -s -w 86")
  `go doc` collects the option constructors under the `Option` type, which
  is how users discover them:
  #output("ch02/s2-doc.txt", cmd: "go doc . Option")
  #troubleshoot(
    ([#ts("s2-funcvalue.txt")], [A plain function was passed as a `TokenSource`. Functions have no methods.], [Convert it: `platformapi.TokenSourceFunc(f)`. See "Function types with methods".]),
    ([#ts("s2-signature.txt")], [The method exists but its signature differs from the interface's. The `have` and `want` lines show how.], [Match the signature exactly, context included.]),
    ([#ts("s2-ptrrecv.txt")], [`Wait` has a pointer receiver, and a value was passed.], [Pass `&countingLimiter{}`. See "Method sets".]),
    ([#ts("s2-reconfigure.txt")], [An option was applied to a built client. Options take the unexported `*config`, so this can't compile, by design.], [Pass options to `New`. A client is immutable once built.]),
  )
]

#step(3, 8, "Typed errors", label: <sec-api-s3>)

So far a failed call returns a string such as `404 Not Found`. A program can
print that, but it can't act on it without parsing text, and a message
written for people is not a contract. This step gives errors a type that
programs can inspect and a few sentinel values they can compare against.

#goconcept(title: [Errors are values, and can have types])[
  `error` is a one-method interface built into the language:
  `type error interface { Error() string }`. Any type with that method is
  an error, so an error can carry fields: a status code, a request ID, a
  delay. Code adds context by _wrapping_:
  `fmt.Errorf("deploying %s: %w", svc, err)` keeps `err` inside, reachable
  through an `Unwrap` method. `errors.Is(err, target)` walks that chain
  looking for an error equal to `target`, or one whose `Is(target)` method
  says yes. `errors.As(err, &p)`, and since Go 1.26 the generic
  `p, ok := errors.AsType[*APIError](err)`, finds an error of a given type
  and hands it back. Comparing errors with `==` misses wrapped errors, and
  the `errorlint` linter flags it. Chapter 0 introduced wrapping; Chapter 3
  covers error design in depth.
]

Create `errors.go`:

#src("workbook/ch02/step3/errors.go", region: "errors")

`Code` is the field programs should branch on, and `Message` is for people.
`RequestID` is in the error text on purpose: it is what a user pastes into
a support ticket, and it finds the server's log lines for that call.
`RetryAfter` holds the server's opinion on when to try again, which step 7's
retries use.

The `Is` method lets callers write `errors.Is(err, platformapi.ErrNotFound)`
without the SDK exporting a sentinel per status code, and without callers
comparing `StatusCode` against numbers. It is defined on `*APIError`, so the
pointer is the error type: `errors.AsType[*platformapi.APIError](err)`. Two
sentinels is a deliberately small vocabulary. They name the conditions
callers really branch on (create it if it doesn't exist, wait if someone
else is deploying), and everything else is in the `*APIError`.

The client has to build these errors from responses. Add `cmp` and
`strconv` to the imports of `transport.go`:

#src("workbook/ch02/step3/transport.go", region: "imports")

In `getJSON`, the status check changes. Replace the function:

#src("workbook/ch02/step3/transport.go", region: "getjson")

and add `decodeError` at the end of the file:

#src("workbook/ch02/step3/transport.go", region: "decode")

Servers and proxies don't always send the API's JSON error shape. A load
balancer's 502 page or a firewall's 403 is plain text, so `decodeError`
falls back to the status text for the code and the first 200 bytes of the
body for the message. `io.LimitReader` stops a 50 MB error page from being
read into memory. `Retry-After` comes in two formats, seconds or an HTTP
date, and both are handled. `cmp.Or` returns its first non-zero argument,
which makes "this, or else that" a one-liner.

The function returns `*APIError`, the concrete type, and `getJSON` returns
it as an `error`. That is safe here because `decodeError` never returns
`nil`. Step 6 shows what happens when a nil pointer of an error type ends up
in an `error` variable.

=== Tests

Create `errors_test.go`:

#src("workbook/ch02/step3/errors_test.go", region: "head")

The test logs the error, so `go test -v` shows exactly what a user would
see. Then two failure shapes from the real world:

#src("workbook/ch02/step3/errors_test.go", region: "escape")

`TestIDsCannotEscapeTheirPath` is a small security test. Without the
per-segment escaping in `url`, the ID `../environments/prod` would be sent
as a path, Go's `ServeMux` would clean it to `/v1/environments/prod` and
redirect, and the client would follow the redirect and happily decode the
production environment into a `Deployment`. The checkpoint shows that
exact failure. `TestErrorsFromProxiesKeepTheirText` uses
`http.HandlerFunc`, the standard library's function adapter, to build a
one-line server that behaves like a web application firewall.

#needspace(12em)
#checkpoint(step: 3, of: 8, title: [Typed errors])[
  #output("ch02/s3-tree.txt", cmd: "find . -name '*.go' | sort")
  #output("ch02/s3-test.txt", cmd: "go vet ./... && go test ./...")
  What a user sees when a deployment doesn't exist. The request ID came
  from the fake, because the client doesn't send one yet:
  #output("ch02/s3-log.txt", cmd: "go test -v -run TestNotFoundIsAnAPIError . | fold -s -w 86")
  #troubleshoot(
    ([#ts("s3-equal.txt")], [An error was compared with `!=` (or `==`) instead of `errors.Is`. It works until someone wraps the error.], [`errors.Is(err, platformapi.ErrNotFound)`.]),
    ([#ts("s3-nois.txt")], [`*APIError` has no `Is` method, so `errors.Is` compares pointers, and an `*APIError` is never equal to the sentinel.], [Add the `Is` method.]),
    ([#ts("s3-escape.txt")], [The ID was not escaped, so `..` climbed out of `/v1/deployments/`; the server redirected and the client fetched another resource.], [Escape every segment with `url.PathEscape`; see "Three ways to get a resource".]),
    ([#ts("s3-astype.txt")], [`errors.AsType` was asked for `APIError`, a value type, but only `*APIError` has the `Error` method.], [Ask for the pointer: `errors.AsType[*platformapi.APIError]`.]),
  )
]
