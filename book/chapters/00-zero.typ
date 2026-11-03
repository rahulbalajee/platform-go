#import "../template/book.typ": *

#chapter(0, "Go from Zero: Programming Fundamentals by Building a Real Tool", label: <ch-zero>,
  abstract: [
    Every later chapter in this book assumes you can read and write Go. This
    one makes no assumption at all. It starts before the first line of code,
    with installing Go and finding your way around a terminal, and ends with
    a tested command-line tool that reads many log files at once. Along the
    way it explains what a program, a variable, a function and a type are,
    and then the Go ideas the rest of the book leans on: errors as values,
    `io.Reader`, structs and methods, packages, tests, interfaces, generics
    and goroutines.
  ],
  learn: (
    [Install Go 1.27, use a terminal, set up an editor that formats and checks your code],
    [Read compiler errors, panics and test failures, and fix what they point at],
    [Variables, types, control flow, functions and errors as values],
    [Files and streams: `os.Open`, `defer`, `io.Reader`, `io.ReadAll` and `bufio.Scanner`],
    [Slices, maps, structs, methods, packages and table-driven tests],
    [Interfaces and the designs they allow, `io.Writer`, JSON and generics],
    [Goroutines, channels, `sync.WaitGroup` and the race detector; wrapping errors],
  ),
  build: [
    *`logq`*, a command-line tool that filters and summarizes log files, built
    from an empty directory in 14 steps. The finished tool reads files or
    standard input, filters by level, text or regular expression, prints text
    or JSON, ranks the busiest services, explains its errors, and scans many
    files concurrently.
  ],
)

== How to use this chapter <sec-zero-how>

This chapter has two kinds of reader, and it is written for both at once.

If you have never programmed, read everything in order. Each new idea is
explained in plain words the first time it appears, and nothing is used
before it is explained. You will meet a lot of new vocabulary; the boxes
marked *Go concept* hold the definitions, and you can come back to them
whenever a later step uses the idea again.

If you already program in Python, Java, JavaScript or a similar language,
you can move faster. Skim the explanations of what a variable or a loop is,
and read the Go concept boxes for the parts that differ from what you know.
Those boxes end with a short comparison where it helps. Do not skip the
build steps, though. Go has a few habits (errors returned as values, small
interfaces, explicit conversions) that only feel natural after you have typed
them a dozen times.

=== The loop this book runs on

You learn to program by writing programs that do not work yet and then
finding out why. This chapter is built around that loop. After the setup,
you build one tool, `logq`, in 14 steps. Each step adds one idea, prints
every line of code you need, and ends with a *checkpoint*: the commands to
run and the exact output you should see. That output is not made up; a
script ran every command in this chapter on a real machine and saved what
it printed.

When your output matches, move on. When it does not, the checkpoint has a
table of the mistakes people really make at that step, each with the error
it produces and where to read again. Those errors were produced the same
way: by breaking a copy of the step's code on purpose and recording what Go
said. @fig-zero-loop shows the loop.

#fig(caption: [The loop every build step follows. Failing is part of it: the troubleshooting table sends you back to the explanation you need.])[
  #diagram(
    spacing: (16pt, 18pt),
    dnode((0, 0), [read the step], kind: "muted"),
    dnode((1, 0), [type the code], kind: "default"),
    dnode((2, 0), [run the checkpoint\ commands], kind: "accent"),
    dnode((3, 0), [next step], kind: "good"),
    dnode((2, 1), [output differs:\ find the symptom\ in the table], kind: "warn"),
    dnode((0, 1), [re-read the section\ it points to], kind: "muted"),
    dedge((0, 0), (1, 0), "-|>"),
    dedge((1, 0), (2, 0), "-|>"),
    dedge((2, 0), (3, 0), "-|>", label: [matches]),
    dedge((2, 0), (2, 1), "-|>"),
    dedge((2, 1), (0, 1), "-|>"),
    dedge((0, 1), (1, 0), "-|>", label: [fix]),
  )
] <fig-zero-loop>

All the code is also in the book's repository, one directory per step
(`workbook/ch00/step1` to `step14`), so you can compare your files with a
known-good copy. Try to get there from the text first. Comparing files is a
last resort, because the repository cannot tell you _why_ your version
differs, and the why is the part you are here to learn.

=== What a program is

A computer does exactly what it is told, one small instruction at a time:
add these two numbers, copy these bytes, jump to that instruction if this
value is zero. Those instructions are _machine code_, numbers that a
particular kind of processor understands. Nobody writes machine code by
hand. You write _source code_, text in a programming language that people
can read, and a program called a _compiler_ translates it into machine code.

Go is a _compiled_ language. You write source files ending in `.go`, the
`go build` command compiles them, and the result is an _executable_ (also
called a binary): a file of machine code that your operating system can run
directly. Python and JavaScript usually work differently: an interpreter
reads your source code every time the program runs. Java sits in between,
compiling to bytecode that a virtual machine runs. A Go executable needs
neither the source code nor Go itself to run. You can copy it to another
machine of the same kind and run it there.

#fig(caption: [From source code to a running program. The compiler checks the whole program before anything runs, so many mistakes are caught at the second box, not in production.])[
  #diagram(
    spacing: (18pt, 14pt),
    dnode((0, 0), [`main.go`\ source code\ (text you write)], kind: "muted"),
    dnode((1, 0), [`go build`\ compiler and linker], kind: "accent"),
    dnode((2, 0), [`logq`\ executable\ (machine code)], kind: "dark"),
    dnode((3, 0), [running process\ reads stdin,\ writes stdout, stderr], kind: "good"),
    dedge((0, 0), (1, 0), "-|>"),
    dedge((1, 0), (2, 0), "-|>"),
    dedge((2, 0), (3, 0), "-|>", label: [OS runs it]),
  )
] <fig-zero-build>

When a program runs, the operating system creates a _process_ for it and
gives it three streams of text: _standard input_ (stdin), where it can read
what is typed or piped into it, _standard output_ (stdout), for its normal
results, and _standard error_ (stderr), for messages about problems. When
the process ends, it hands back a small number, its _exit status_: 0 means
success, anything else means something went wrong. Shell scripts and CI
pipelines read that number to decide what to do next. `logq` uses all four
of these by Step 10.

The compiler is strict, and that is good news. Before Go produces an
executable it checks that every name you use exists, that you never put a
piece of text where a number belongs, and a long list of other things. A
mistake it catches costs you ten seconds. The same mistake found by a user
at three in the morning costs a lot more.

=== Go, and why platform teams use it

Go was designed at Google and released as open source in 2009, with the
stable 1.0 release in 2012. A new version comes out every six months, in
February and August; this book uses Go 1.27, from August 2026. Go promises
that a program written for any Go 1 version keeps compiling with later ones,
so code you write today keeps working.

Much of the software platform engineers run every day is written in Go:
Docker, Kubernetes, etcd, Terraform, Prometheus, Helm and Argo CD among
them. Teams that build tooling around those systems use Go for the same
reasons their authors did:

- *One file to ship.* `go build` produces a single executable. A tool built
  only from Go's standard library has no runtime to install and no
  libraries to match, which makes it easy to put in a container or hand to
  another team.
- *Cross-compilation is one setting.* Building a Linux binary on a Mac, or
  a Windows binary on Linux, takes two environment variables (you will do
  it in a few pages).
- *A large standard library.* HTTP clients and servers, JSON, TLS,
  compression, testing and much more come with Go. `logq` uses nothing
  else.
- *Concurrency is built in.* Platform tools spend their time waiting on
  networks and disks. Go's goroutines make it practical to wait on
  thousands of things at once, and Step 14 shows the basics.
- *Fast builds and a small language.* A large Go program compiles in
  seconds, and the language is small enough that code written by someone
  else reads much like code you wrote yourself.

The trade-offs are real too. Go is more verbose than Python for small
scripts, its error handling is explicit to the point of repetition, and it
has fewer abstractions than Java or Rust. This book argues, chapter by
chapter, that those trade-offs are the right ones for infrastructure code
that many people maintain for years.

== Installing Go <sec-zero-install>

Install Go 1.27 or later from the official downloads page, *go.dev/dl*. Pick
the file for your operating system and processor: `darwin-arm64` for a Mac
with Apple silicon, `darwin-amd64` for an Intel Mac, `linux-amd64` or
`linux-arm64` for Linux, and `windows-amd64` for most Windows machines.

*macOS.* Download the `.pkg` file and open it. The installer puts Go in
`/usr/local/go` and adds `/usr/local/go/bin` to the list of places your
terminal looks for programs. If you use Homebrew, `brew install go` works
too. Go 1.27 needs macOS 13 Ventura or later.

*Linux.* Download the `.tar.gz` file, remove any old copy, and unpack it
into `/usr/local` (the commands below need administrator rights, hence
`sudo`; replace the file name with the one you downloaded):

#code(file: "terminal")[```
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go1.27.3.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> ~/.profile
```]

The last line tells your shell where Go lives (the next section explains
`PATH`). It takes effect in new terminal windows, or after you run
`source ~/.profile`. Distribution packages such as `apt install golang`
are often several versions behind, so prefer the official download.

*Windows.* Download the `.msi` file and run it. The installer puts Go under
`C:\Program Files\Go` and updates `PATH` for you. Close and reopen any
terminal windows afterwards, because a terminal reads `PATH` only when it
starts.

Now open a terminal (the next section shows how) and check the install.
`go version` prints the version of the Go command, and `which go` prints
where it is (on Windows, use `where go`):

#output("ch00/setup-version.txt")

Any version from `go1.27.0` up is fine. If the terminal says the command
`go` is not found, the install did not update your `PATH`, or the terminal
was already open before you installed; open a new one and try again.

#note(title: [Go downloads newer Go when it needs to])[
  Each Go project says which Go version it needs, in a file called
  `go.mod`. If a project asks for a newer version than the one you
  installed, the `go` command downloads that version automatically into
  `~/go` and uses it for that project. This is why you can install Go once
  and still build projects that need a later release. You will see the
  version line in `go.mod` shortly.
]

== A terminal survival kit <sec-zero-terminal>

A _terminal_ is a window where you type commands instead of clicking.
The program inside it that reads your commands is the _shell_: zsh on
macOS, usually bash on Linux, and PowerShell on Windows. Platform work
happens in terminals, so it pays to be comfortable in one.

To open one: on macOS, press #kbd("Cmd-Space"), type _Terminal_ and press
#kbd("Enter"). On Linux, look for _Terminal_ in your applications (often
#kbd("Ctrl-Alt-T")). On Windows, open _Windows Terminal_ or _PowerShell_
from the Start menu. Editors such as VS Code also have a terminal built in
(#kbd("Ctrl-`") opens it).

The shell shows a _prompt_ and waits. In this book, a line that starts with
`$` is a command for you to type (without the `$`), and the lines after it
are what the command printed. Here is a short session that creates a
directory, moves into it, creates a file and looks at it:

#output("ch00/setup-terminal.txt")

You are always _in_ some directory, the _current directory_. When you run a
command, it works on files in the current directory unless you name a
different path. These are the commands you need for this chapter:

#table(
  columns: (auto, auto, 1fr),
  table.header([macOS, Linux], [Windows PowerShell], [What it does]),
  [`pwd`], [`pwd`], [Print the current directory],
  [`ls`], [`ls` or `dir`], [List the files in the current directory],
  [`cd logq`], [`cd logq`], [Change into the directory `logq`],
  [`cd ..`], [`cd ..`], [Go up one level, to the parent directory],
  [`cd ~`], [`cd ~`], [Go to your home directory],
  [`mkdir logq`], [`mkdir logq`], [Make a new directory],
  [`cat app.log`], [`cat app.log` or `type app.log`], [Print a file],
  [`./logq`], [`.\logq.exe`], [Run a program in the current directory],
  [`echo $?`], [`echo $LASTEXITCODE`], [Print the exit status of the last command],
)

A few habits save a lot of time:

- Press #kbd("Tab") to complete a file or directory name, and the up arrow
  to bring back the previous command.
- Press #kbd("Ctrl-C") to stop a program that is running. A program that
  waits for you to type something ends its input when you press
  #kbd("Ctrl-D") (on Windows, #kbd("Ctrl-Z") then #kbd("Enter")).
- `|` (a _pipe_) sends one command's output into another command's input:
  `cat app.log | logq` feeds the file to `logq`. `>` writes a command's
  output to a file, replacing it; `>>` appends to it.
- If a path has spaces in it, put it in quotes.

=== What PATH is

When you type `go version`, how does the shell find a program called `go`?
It looks in a list of directories, in order, and runs the first file called
`go` that it finds. That list is an _environment variable_ called `PATH`,
and `echo $PATH` prints it (on Windows, `$env:Path`). Installing Go adds
`/usr/local/go/bin` (or the Windows equivalent) to that list; that is all
"adding Go to your PATH" means.

Programs you install with `go install` go into a second directory,
`~/go/bin`. Add it to `PATH` the same way if you want to run those programs
by name. A program in your current directory is not found by name on macOS
and Linux, for safety, which is why you run it as `./logq`.

== An editor that helps <sec-zero-editor>

You can write Go in any text editor, but an editor that understands Go
catches mistakes as you type and keeps your code formatted. This book
assumes *Visual Studio Code* (free, from code.visualstudio.com) with the
official Go extension; GoLand, Neovim, Zed and Emacs all work well too,
because they talk to the same Go language server.

+ Install VS Code and open it.
+ Open the Extensions view (the four squares on the left), search for _Go_,
  and install the extension published by the Go Team at Google.
+ Open the Command Palette (#kbd("Cmd-Shift-P") on macOS,
  #kbd("Ctrl-Shift-P") elsewhere), run _Go: Install/Update Tools_, select
  all the tools and press OK.

The most important of those tools is *gopls* (pronounced "go please"), the
Go language server. It runs in the background and gives the editor what it
needs to underline errors before you compile, show documentation when you
hover over a name, jump to where something is defined, and rename safely.

The extension formats Go files every time you save, using the same rules
as the `go fmt` command, and adds or removes `import` lines for you. Check
that it is on: open Settings, search for _format on save_, and make sure it
is ticked for Go. If you prefer editing the settings file directly, these
are the relevant entries:

#code(file: "settings.json")[```json
{
  "[go]": {
    "editor.formatOnSave": true,
    "editor.codeActionsOnSave": { "source.organizeImports": "explicit" }
  }
}
```]

All Go code in the world is formatted the same way, by the same tool. You
never argue about tabs and braces, and any Go file you open looks familiar.
Let the editor do it and stop thinking about layout.

== Hello, world <sec-zero-hello>

Every Go program lives in a _module_: a directory with a file called
`go.mod` at its top that names the module and the Go version it needs.
Create a directory for a first program and turn it into a module with
`go mod init`:

#output("ch00/hello-init.txt")

`go mod init hello` wrote `go.mod` with two lines: the module's name and
the Go version it was created with. You will rarely edit this file by
hand; Go commands maintain it.

Now create a file called `main.go` in the `hello` directory with this
content. Type it rather than pasting it; your fingers learn the shape of
the language that way.

#src("workbook/ch00/hello/main.go")

Run it with `go run .` (the dot means "the package in the current
directory"). Then build an executable with `go build` and run that:

#output("ch00/hello-run.txt")

`go run` compiled the program and ran it in one go, without leaving an
executable in your directory, which is convenient while you work.
`go build` left an executable called `hello` (on Windows, `hello.exe`)
that runs without Go.

Here is what each part of `main.go` means:

- `package main` says which _package_ this file belongs to. A package is a
  group of Go files in one directory that are compiled together. The name
  `main` is special: it tells Go to build an executable rather than a
  library for other programs to use.
- `import "fmt"` makes the standard library's `fmt` package available.
  `fmt` (short for _format_) prints and formats text.
- `func main() { ... }` defines a _function_ called `main`. A function is a
  named block of code you can run, and `main` in package `main` is where
  every Go program starts. The braces mark where the function's body begins
  and ends.
- `fmt.Println("Hello, platform engineer!")` _calls_ the function `Println`
  from package `fmt`, passing it a piece of text. `Println` prints its
  arguments followed by a new line. Text in double quotes is a _string_.

#goconcept(title: [Compared with Python, Java and JavaScript])[
  Go has no top-level scripts: code runs only from `main` (or from the
  functions it calls). Blocks use braces, as in Java and JavaScript, and
  indentation is cosmetic, unlike Python; `go fmt` indents with tabs.
  Statements end at the end of the line, so there are no semicolons to
  type. Names from another package are always written with the package
  name in front (`fmt.Println`), so you can tell at a glance where
  something comes from.
]

=== One command, three operating systems

Go can build an executable for a different operating system or processor
than the one you are on. Set `GOOS` (the target operating system) and
`GOARCH` (the target processor) for one command:

#output("ch00/hello-cross.txt")

`file` describes what is inside a file. The first build is a macOS program
for Apple silicon. The next two, built on the same Mac in a second or two,
are a Linux program for x86-64 servers and a Windows program. Copy
`hello-linux` into a Linux container and it runs, with nothing else
installed. This is one of the main reasons platform teams choose Go.

=== Reading a compiler error

You will see compiler errors constantly, and reading them well is a skill
worth practising from day one. Change `Println` to `Prinln` (a typo) in
`main.go` and run the program again:

#output("ch00/hello-err-undefined.txt")

Read it in parts. `# hello` names the package that failed to compile.
`./main.go:6:6:` is the file, the line (6) and the column (6) where the
compiler noticed the problem. Then comes the message,
`undefined: fmt.Prinln`, meaning there is no such name in package `fmt`.
Editors show
the same message as a red underline at that position.

Fix the typo, then delete the closing quote after the exclamation mark:

#output("ch00/hello-err-quote.txt")

One mistake, two messages. The compiler reached the end of line 6 still
inside a string, reported that, and then got confused about the rest of the
line. When you see several errors, fix the first one and compile again;
later errors are often consequences of the first. Put the quote back before
you continue.

=== Formatting

Here is the same program written without any care for layout, then
formatted by `go fmt`, which rewrites files in place and prints the names
of the files it changed:

#output("ch00/hello-fmt.txt")

Your editor does this on every save. The Go community treats `go fmt`
output as the only correct layout, and many teams' CI checks fail on
unformatted code, so get used to letting the tool decide.

You now have everything the build needs: Go, a terminal and an editor.
Delete the `hello` directory, or keep it as a scratch pad for trying things
out.

== What we're building <sec-zero-what>

Every service writes logs, and the first thing anyone does during an
incident is search them. `grep` finds text, but it does not know that a log
line has a time, a severity level and a service name, so it cannot answer
"show me warnings and worse", "how many errors did each service log" or
"give me those lines as JSON for the next tool". `logq` can. It reads log
lines of this shape:

#code(file: "app.log (one line)")[```
2026-11-03T09:02:40Z ERROR api GET /orders 500 timeout talking to db
```]

The four parts, separated by spaces, are the time (in the standard format
called RFC 3339; the `Z` means UTC), the level (`DEBUG`, `INFO`, `WARN` or
`ERROR`), the service that wrote the line, and a free-text message that
runs to the end of the line.

Here is the finished tool at work. Show warnings and errors from two files;
with more than one file, each line starts with the file name, as with
`grep`:

#output("ch00/demo-1.txt")

Select errors whose message contains `reset` and print them as JSON, one
object per line, ready for another program to read:

#output("ch00/demo-2.txt", size: 6.6pt)

Read from standard input, count entries by level, and rank the three
services with the most entries. The first line of output is a warning, on
standard error, about a line in `app.log` that is not a valid entry:

#output("ch00/demo-3.txt")

And refuse bad input outright when asked to, with a hint and an exit
status that a CI job can act on:

#output("ch00/demo-4.txt")

@fig-zero-flow shows how the finished program is put together. Do not
worry about the names yet; every box is built and explained in one of the
steps.

#fig(caption: [Inside the finished `logq`. Each file is scanned in its own goroutine; lines become `Entry` values, a `Matcher` decides which to keep, and the results are printed in command-line order.])[
  #diagram(
    spacing: (14pt, 16pt),
    dnode((0, 0), [files or stdin\ `io.Reader`], kind: "muted"),
    dnode((1, 0), [`bufio.Scanner`\ one line at a time], kind: "default"),
    dnode((2, 0), [`logline.Parse`\ line → `Entry`], kind: "accent"),
    dnode((3, 0), [`match.Matcher`\ keep or drop], kind: "accent"),
    dnode((3, 1), [text or JSON\ to an `io.Writer`], kind: "good"),
    dnode((2, 1), [`logline.Stats`\ counts per level,\ per service], kind: "default"),
    dnode((1, 1), [`-count`, `-top`\ via `rank.Top`], kind: "good"),
    dnode((0, 1), [exit status\ 0, 1 or 2], kind: "dark"),
    dedge((0, 0), (1, 0), "-|>"),
    dedge((1, 0), (2, 0), "-|>"),
    dedge((2, 0), (3, 0), "-|>"),
    dedge((3, 0), (3, 1), "-|>"),
    dedge((3, 0), (2, 1), "-|>"),
    dedge((2, 1), (1, 1), "-|>"),
  )
] <fig-zero-flow>

The build takes 14 steps. Each one leaves you with a program that compiles
and runs, and each adds one or two ideas:

#table(
  columns: (auto, 1.25fr, 1.3fr),
  table.header([Step], [What it adds to `logq`], [Go concepts it introduces]),
  [1], [Print facts about one log line], [`package main`, variables, `:=`, basic types, constants, `fmt`],
  [2], [Count levels in a log written into the program], [`for` and `range`, `if`, `switch`, strings],
  [3], [Split the work into functions; report bad lines], [functions, multiple results, `error`, standard error],
  [4], [Read the log from a file named on the command line], [`os.Args`, `os.Open`, `defer`, `io.Reader`, `io.ReadAll`, bytes],
  [5], [Read files of any size, one line at a time], [`bufio.Scanner`, streaming, long lines],
  [6], [Count levels in a map; keep bad lines in a slice], [slices, `append`, maps, zero values],
  [7], [Parse each line into a struct], [structs, methods, pointer and value receivers, `time`],
  [8], [Move parsing into a package of its own], [packages, imports, exported names, `iota`],
  [9], [Test the parser], [`go test`, table-driven tests, coverage, linters],
  [10], [Flags, standard input, exit codes], [`flag`, `os.Stdin`, `os.Exit`, function values],
  [11], [Filters as types; output to any writer], [interfaces, `io.Writer`, type switches],
  [12], [JSON output and a ranking of services], [`encoding/json`, struct tags, generics],
  [13], [Errors with context and hints], [`%w`, `errors.Is`, `errors.As`, error types],
  [14], [Scan many files at once], [goroutines, channels, `sync.WaitGroup`, `-race`],
)

#step(1, 14, "Variables, types and constants", label: <sec-zero-s1>)

The first version of `logq` does not read any logs yet. It holds one log
line and a few numbers in variables and prints facts about them. That is
enough to meet the pieces every Go program is made of.

Start in your home directory, make a directory for the project, move into
it and create the module:

#output("ch00/s1-init.txt")

`go mod init logq` created `go.mod`, naming the module `logq`. Its second
line, `go 1.27.3` on the machine used for this book, records your Go
version; yours may differ slightly, which is fine. Everything from now on
happens inside this `logq` directory.

Create `main.go`:

#src("workbook/ch00/step1/main.go")

Read it from the top. Lines that start with `//` are _comments_: notes for
people, ignored by the compiler. A comment directly above a declaration is
its _doc comment_, and Go's tools show it as documentation, so every
important name in this book gets one.

`const version = "0.1.0"` declares a _constant_ named `version`. Inside
`main`, each of the next lines declares a _variable_: a name for a value
that the program keeps in memory and can change. `tool := "logq"` creates a
variable called `tool` and stores the string `"logq"` in it. `len(line)`
asks for the length of the string in `line`, in bytes. `errorCount == 0`
compares two numbers and produces `true` or `false`, which is stored in
`healthy`.

The `fmt` lines at the end print. `Println` prints its arguments separated
by spaces. `Printf` takes a _format string_ in which each _verb_, a `%`
followed by a letter, is replaced by the next argument: `%d` prints a whole
number, `%.1f` a number with one digit after the decimal point, and `%%` a
literal percent sign. `\n` inside a string means "new line"; `Printf`, unlike
`Println`, does not add one for you.

#goconcept(title: [Variables, types and zero values])[
  Every value in Go has a _type_, which says what kind of value it is and
  what you can do with it. The ones in this step are:

  #table(
    columns: (auto, 1fr, auto),
    table.header([Type], [Holds], [Zero value]),
    [`string`], [text, as a sequence of bytes], [`""`],
    [`int`], [a whole number (64 bits on a 64-bit machine)], [`0`],
    [`float64`], [a number with a fractional part], [`0`],
    [`bool`], [`true` or `false`], [`false`],
  )

  There are two ways to declare a variable. `var warnCount int` names the
  variable and its type; because no value is given, it starts at the type's
  _zero value_, here `0`. Go never leaves a variable uninitialized, so there
  is no "undefined" or garbage value to worry about. `tool := "logq"` is the
  short form: it declares and assigns in one go, and the compiler works out
  the type from the value. The short form only works inside functions, and
  it is what Go code uses most of the time.

  `:=` declares a _new_ variable; `=` assigns to one that already exists:

  #code(file: "sketch")[```go
  count := 1    // declare count and set it to 1
  count = 2     // change it: count already exists
  count := 3    // error: no new variables on left side of :=
  ```]

  Two rules surprise newcomers. First, a variable you declare inside a
  function and never use is a compile error, and so is an `import` you
  never use. Go treats both as likely mistakes rather than clutter to warn
  about. Second, Go never converts between number types on its own.
  `errorCount` and `total` are `int`, so `errorCount / total` is integer
  division (4 / 18 is 0). To get 22.2, convert both to `float64` first, as
  `float64(errorCount)` does.

  _Coming from Python or JavaScript:_ variables have one type for their
  whole life; `tool = 5` after `tool := "logq"` does not compile.
  _Coming from Java:_ there are no primitive wrapper classes and no `null`
  for these types; the zero value takes its place.
]

#goconcept(title: [Constants])[
  A constant is a value fixed when the program is compiled:
  `const version = "0.1.0"`. You cannot assign to it later. Constants
  declared outside any function, like this one, can be used anywhere in the
  package. Numeric constants are _untyped_ until they are used, which is
  why `share` can be computed as a `float64` with the plain number `100` in
  the expression: the constant takes whatever type the expression needs.
  Use constants for values that are part of the program's design (a
  version, a size limit) rather than its data.
]

#goconcept(title: [Printing with fmt])[
  `fmt.Println(a, b, c)` prints its arguments with spaces between them and
  a new line at the end. `fmt.Printf(format, args...)` fills in the verbs
  of the format string, in order. The verbs you will use most:

  #table(
    columns: (auto, 1fr),
    table.header([Verb], [Prints]),
    [`%v`], [any value in a default format (the safe choice)],
    [`%d`], [an integer in decimal],
    [`%s`, `%q`], [a string; `%q` adds double quotes and escapes, handy for showing exact text],
    [`%.1f`], [a floating-point number with one decimal place],
    [`%t`], [a boolean],
    [`%-6s`], [a string padded with spaces to 6 columns, left-aligned],
    [`%%`], [a literal `%`],
  )

  If a verb and its argument do not match, `Printf` does not crash; it
  prints a marker such as `%!f(int=0)` in the output. `go vet` catches most
  of these mismatches before you run the program, as the troubleshooting
  table below shows. `fmt.Sprintf` works like `Printf` but returns the
  string instead of printing it.
]

#checkpoint(step: 1, of: 14, title: [A program that runs])[
  You should have:

  #code(file: "logq/")[```
  logq/
  ├── go.mod
  └── main.go
  ```]

  Run the program, then run `go vet`, Go's built-in checker for suspicious
  code. `go vet` prints nothing when it finds nothing:

  #output("ch00/s1-run.txt")

  The most instructive mistake at this step compiles and runs. Forget the
  `float64` conversions and write `share := errorCount / total * 100`:

  #output("ch00/s1-intdiv.txt")

  Integer division made `share` an `int` with the value 0, and `%.1f`
  cannot print an `int`, so `Printf` printed a marker instead. `go vet`
  pointed straight at it. Run `go vet` whenever output looks wrong.

  #troubleshoot(
    ([`declared and not used: debug`], [You declared a variable and never used it (here, `debug := true`)], [Use it or delete it; see "Variables, types and zero values"]),
    ([`"os" imported and not used`], [An `import` line names a package the file does not use], [Delete the import; your editor removes unused imports on save]),
    ([`undefined: size`, reported twice], [You wrote `size = len(line)`, assigning to a variable that was never declared], [Use `:=` to declare a new variable]),
    ([`invalid operation: float64(errorCount) / total (mismatched types float64 and int)`], [You converted one side of `/` but not the other; Go never mixes number types], [Convert both: `float64(errorCount) / float64(total)`]),
    ([`syntax error: non-declaration statement outside function body`], [You used `:=` outside a function (`version := "0.1.0"`)], [Outside functions, use `const` or `var`]),
    ([`%!f(int=0)` in the output, and `go vet` reports `format %.1f has arg share of wrong type int`], [Integer division: both operands were `int`], [Convert to `float64` before dividing]),
  )
]

#step(2, 14, "Decisions and loops", label: <sec-zero-s2>)

One log line is not a log. This step puts six lines into the program and
walks through them one by one, counting how many there are of each level.
That needs two new abilities: doing something repeatedly (a _loop_) and
choosing between actions (a _decision_).

Replace the whole of `main.go` with:

#src("workbook/ch00/step2/main.go")

The log is a _raw string literal_, written between backquotes. Unlike a
double-quoted string, it can span several lines, and backslashes in it are
plain characters. Line 5 of the sample, `2026-11-03T09:04`, is a line that
was cut off, as happens when a process crashes halfway through writing.
Real logs contain lines like that, and `logq` has to survive them.

`strings.Split(sample, "\n")` cuts the text at every line break and
returns the pieces as a _slice_ of strings, Go's name for a list. Step 6
covers slices properly; for now you need two things. `len(lines)` is how
many items it holds, and `for i, line := range lines` runs the loop body
once per item, with `i` set to the item's position (counting from 0) and
`line` to the item itself. That is why the program prints `i+1`: people
count lines from 1.

`strings.Fields(line)` splits a line at runs of spaces into its words. A
valid line has at least three. The `if` statement checks that, and
`continue` skips the rest of the loop body and moves on to the next line.
The `switch` compares the second word, `fields[1]`, with each `case` in turn
and runs the first one that matches. `debug++` adds 1 to `debug`.

#goconcept(title: [Loops: for is the only one])[
  Go has one loop keyword, `for`, in four shapes:

  #code(file: "sketch")[```go
  for i := 0; i < 3; i++ { ... }    // counter: init; condition; post
  for n < 100 { ... }              // like "while" in other languages
  for { ... }                       // forever, until break or return
  for i, v := range items { ... }  // each index and value of a slice
  ```]

  The counter form runs `i := 0` once, then repeats while `i < 3` is true,
  running `i++` after each pass. `range` also works over maps, strings,
  channels and integers (`for i := range 10` counts 0 to 9). If you do not
  need the index, write `for _, v := range items`; the blank identifier `_`
  throws a value away, which matters because an unused `i` is a compile
  error. Inside any loop, `continue` jumps to the next pass and `break`
  leaves the loop.

  _Coming from C or Java:_ the counter loop has no parentheses, and the
  braces are required even for one line. _Coming from Python:_ `range`
  gives you the index and the value together, like `enumerate`.
]

#goconcept(title: [if, else and switch])[
  `if` takes a condition that must be a `bool`; there is no "truthiness",
  so `if errorCount` does not compile when `errorCount` is a number. Write
  `if errorCount > 0`. The `else` must sit on the same line as the closing
  brace before it (`} else {`), because Go ends statements at line breaks.

  `if` can start with a short statement, separated by a semicolon, whose
  variables exist only inside the `if` and its `else`:
  `if n := len(fields); n < 3 { ... }`. You will see this shape constantly
  with errors from Step 3 on.

  `switch` compares a value against each `case` and runs the first match.
  Unlike C and Java, a case does not fall through to the next one, so
  there is no `break` to forget, and one case can list several values:
  `case "WARN", "ERROR":`. A `switch` with no value after it,
  `switch { case n < 0: ... case n == 0: ... }`, is a tidy way to write a
  chain of `if`/`else if`. The optional `default` case runs when nothing
  else matches.
]

#goconcept(title: [Strings, bytes and runes])[
  A Go string is an immutable sequence of bytes, normally holding text
  encoded as UTF-8. `len(s)` counts bytes, not characters: `len("café")` is
  5, because `é` takes two bytes. A single character in single quotes, such
  as `'x'`, is a _rune_ (a Unicode code point), not a string. That is why
  `'DEBUG'` is a compile error. The `strings` package has the functions you
  reach for daily: `Split`, `Fields`, `Contains`, `HasPrefix`, `ToUpper`,
  `TrimSpace`, `Join`. Strings compare with `==`.
]

#checkpoint(step: 2, of: 14, title: [Counting levels])[
  Your directory still holds `go.mod` and `main.go`. Run the program:

  #output("ch00/s2-run.txt")

  There are 7 lines in a sample of 6 because the text ends with a line
  break, and splitting `"a\nb\n"` at line breaks gives `"a"`, `"b"` and an
  empty string after the last break. The length check skips it. Files end
  the same way, which is why every version of `logq` from here on skips
  empty lines.

  Remove the length check to see what it protects against. The cut-off
  line 5 has one word, so `fields[1]` asks for an item that does not exist:

  #output("ch00/s2-index.txt")

  This is a _panic_: a mistake the compiler could not see, found while the
  program ran. Go stopped the program, printed what went wrong (index 1 in
  a slice of length 1), and showed where: `main.go:27`, inside `main.main`
  (function `main` in package `main`). The `exit status 2` line comes from
  `go run`, reporting that the program failed. Read a panic the way you
  read a compiler error: message first, then the first line that points
  into your own code.

  #troubleshoot(
    ([`panic: runtime error: index out of range [1] with length 1`], [You indexed a slice past its end; here `fields[1]` on a one-word line], [Check `len` before indexing; see "Loops"]),
    ([`panic: runtime error: index out of range [7] with length 7`], [A counter loop written `i <= len(lines)` runs one pass too many; the last index is `len - 1`], [Use `<` in the condition, or `range`]),
    ([`non-boolean condition in if statement`], [`if errorCount {`: Go has no truthiness], [Compare explicitly: `if errorCount > 0 {`]),
    ([`syntax error: unexpected keyword else, expected }`], [`else` on its own line after `}`], [Write `} else {` on one line]),
    ([`more than one character in rune literal`], [A string in single quotes, `'DEBUG'`], [Strings use double quotes or backquotes; see "Strings, bytes and runes"]),
  )
]

#step(3, 14, "Functions and errors", label: <sec-zero-s3>)

`main` is getting long, and it mixes three jobs: deciding the level of a
line, counting, and printing. This step moves each job into a _function_
of its own, and it changes how bad lines are handled. Instead of quietly
counting them as "skipped", the code that reads a line reports _what_ is
wrong with it, as an error value.

Replace `main.go` again. The file is printed in four parts so each can be
explained; type them one after the other. First the top of the file, where
the sample gains nothing new but the imports change:

#src("workbook/ch00/step3/main.go", region: "head")

Then `main`, which now only loops and counts:

#src("workbook/ch00/step3/main.go", region: "main")

`level, err := parseLevel(line)` calls `parseLevel` and receives _two_
results: the level and an error. If `err` is not `nil` (Go's word for "no
value"), the line was bad: the program prints a message to standard error
and moves on. Here is `parseLevel`:

#src("workbook/ch00/step3/main.go", region: "parse")

Its first line, `func parseLevel(line string) (string, error)`, is the
function's _signature_: it takes one parameter, `line`, of type `string`,
and returns a `string` and an `error`. Every `return` must supply both. On
success it returns the level and `nil`; on failure, an empty string and an
error describing the problem. `errors.New` makes an error from fixed text,
and `fmt.Errorf` makes one from a format string, like `Sprintf`. The `%q`
verb puts the bad level in quotes, so a message about an empty or
space-filled value is still readable.

Last, two small functions for the summary:

#src("workbook/ch00/step3/main.go", region: "summary")

`percent(part, total int)` is a shorthand for
`percent(part int, total int)`. It guards against dividing by zero, which for integers would crash
the program. `printSummary` takes five numbers, which works but is fragile:
nothing stops a caller from passing them in the wrong order, and the
compiler cannot tell, because they are all `int`. Steps 6 and 7 fix that
with better types.

#goconcept(title: [Functions])[
  A function is declared with `func`, a name, its parameters in
  parentheses and its result types:

  #code(file: "sketch")[```go
  func percent(part, total int) float64 { ... }   // one result
  func parseLevel(line string) (string, error) { ... } // two results
  func printSummary(debug, info int) { ... }      // no result
  ```]

  Parameters are copies of the values the caller passed; changing `part`
  inside `percent` does not change anything for the caller. A function
  with results must end every path with a `return` that supplies them, and
  the compiler checks this ("missing return"). The caller must receive all
  results or none: `a, b := f()` for two, or `_` for any you mean to
  ignore. `fmt.Println` accepts any number of arguments of any type; that
  is a _variadic_ function, written `func Println(a ...any)`.

  _Coming from Python:_ multiple results look like returning a tuple, but
  they are not a value you can store as one piece; you unpack them at the
  call. _Coming from Java:_ there is no overloading; each function name has
  exactly one signature in its package.
]

#goconcept(title: [Errors are values])[
  Go has no exceptions for ordinary failures. A function that can fail
  returns an `error` as its last result, and the caller checks it right
  away:

  #code(file: "sketch")[```go
  level, err := parseLevel(line)
  if err != nil {
  	// handle it: report, skip, retry, or return it to your own caller
  }
  // use level: here it is known to be valid
  ```]

  `error` is a built-in type for "something that can describe a failure";
  its `Error()` method returns the message, and `fmt` prints it for you.
  `nil` means no error. When a function returns a non-nil error, its other
  results are usually zero values and should not be used.

  The pattern is repetitive on purpose. Every place that can fail is
  visible in the code, and the decision about what to do is made where the
  failure happens, not in a `catch` block three functions away. Go does
  have `panic` for bugs that should crash the program, as you saw in
  Step 2, but you never use it for things like a missing file or a bad
  line in a log.

  _Coming from Python, Java or JavaScript:_ think of `err` as the
  exception, returned instead of thrown. Step 13 shows how errors carry
  context and how to test for kinds of error.
]

#goconcept(title: [Standard output and standard error])[
  `fmt.Println` writes to standard output. `fmt.Fprintf(os.Stderr, ...)`
  writes to standard error: the `F` functions take the destination as their
  first argument, and `os.Stderr` is standard error (`os.Stdout` is
  standard output). Keep results on standard output and messages about
  problems on standard error, so that `logq app.log > results.txt` saves
  only results while warnings still reach the screen. In a terminal both
  appear in the same window, in the order they were written.
]

#checkpoint(step: 3, of: 14, title: [Errors reported, not hidden])[
  Run it. The first line is the error message for the cut-off line 5,
  written to standard error; the rest is the summary on standard output:

  #output("ch00/s3-run.txt")

  One mistake can produce several errors. Here the call was changed to
  `level := parseLevel(line)` and the error check deleted, a common thing
  to try when the two results feel like a nuisance:

  #output("ch00/s3-mismatch.txt")

  The real problem is the last line: `parseLevel` returns two values and
  the code received one. The two lines above it are knock-on effects:
  deleting the error check removed the only uses of `os` and of `i`.
  Compilers report errors in file order, not in order of importance, so
  read all of them before fixing the first.

  #troubleshoot(
    ([`missing return`], [A path through a function with results reaches the closing brace without a `return`], [Return on every path; see "Functions"]),
    ([`assignment mismatch: 1 variable but parseLevel returns 2 values`], [The call receives fewer results than the function returns], [`level, err := parseLevel(line)`, then check `err`]),
    ([`not enough return values` with `have (string)` and `want (string, error)`], [A `return` in `parseLevel` gives one value where two are needed], [`return level, nil` on success]),
    ([`declared and not used: err`], [You received the error and never looked at it; Go makes ignoring it a compile error], [Add the `if err != nil` check; see "Errors are values"]),
  )
]

#step(4, 14, "Reading a file", label: <sec-zero-s4>)

A tool that only knows the log written into it is not much use. From this
step on, `logq` reads the log file you name on the command line:
`logq app.log`. This is where a program first talks to the world outside
itself, and Go's approach to that, the `io.Reader`, is one of the most
important ideas in the language.

First, the log. Create `app.log` in the `logq` directory with exactly
these 18 lines. Line 11 is deliberately broken, to keep the error handling
honest:

#src("workbook/ch00/step4/app.log")

Now change `main.go`. Replace everything from the top of the file down to
the end of `main`, including the `sample` constant, which is no longer
needed. The new top of the file has new imports:

#src("workbook/ch00/step4/main.go", region: "head")

`main` now checks the command line and hands the real work to a function
called `run`:

#src("workbook/ch00/step4/main.go", region: "main")

`os.Args` holds the command line as a slice of strings: `os.Args[0]` is the
program's own name and `os.Args[1]` the first argument. `logq` needs
exactly one argument, the file name, so with any other count it prints a
usage message and stops with `os.Exit(2)`, the conventional status for
"you called me wrong". If `run` returns an error, `main` prints it with a
`logq:` prefix, so the user knows which program is complaining, and exits
with status 1.

Add `run` and `readLog` after `main`:

#src("workbook/ch00/step4/main.go", region: "run")

#src("workbook/ch00/step4/main.go", region: "readlog")

Keep `parseLevel`, `percent` and `printSummary` from Step 3 exactly as
they are, below these. `run` is the loop from Step 3's `main`, reading
from the file's text instead of the sample; when it finishes, it returns
`nil` to say "no error".

`readLog` is where the reading happens. `os.Open(name)` opens the file and
returns an `*os.File` (the `*` marks a _pointer_, explained in Step 7; for
now read it as "a handle to the open file") and an error, which is not
`nil` if the file is missing or unreadable. `defer f.Close()` arranges for
the file to be closed when `readLog` returns, whichever `return` it takes.
`io.ReadAll(f)` reads the whole file into memory as a `[]byte`, a slice of
bytes, and `string(data)` turns those bytes into a string.

The comment at the end of the `os.Open` line is for a _linter_, a program
that reads code looking for likely bugs (Step 9 sets one up). One linter,
`gosec`, warns whenever a program opens a path that came from the command
line, because in a web service that is often a security hole. For a tool
whose whole job is to read the file you name, it is intended, and the
comment says so. Leave it in.

#goconcept(title: [defer])[
  `defer f.Close()` schedules the call `f.Close()` to run when the
  surrounding function returns, whether it returns normally, early with an
  error, or because of a panic. Put the `defer` right after the line that
  opened the resource and checked for an error, and you cannot forget to
  clean up, however many `return` statements the function grows.

  Deferred calls run in reverse order, last deferred first. The arguments
  are evaluated when the `defer` line runs, not when the call happens. One
  trap: `os.Exit` ends the program immediately and does _not_ run deferred
  calls. That is one reason `main` here is short and the work lives in
  `run`, which returns normally and lets its `defer` statements run.

  _Coming from Python or Java:_ `defer` does the job of `with` or
  `try`-with-resources, without the extra indentation.
]

#goconcept(title: [io.Reader and io.ReadAll])[
  An `io.Reader` is anything you can read bytes from. Its whole definition
  is one method:

  #code(file: "the io package")[```go
  type Reader interface {
  	Read(p []byte) (n int, err error)
  }
  ```]

  `Read` copies up to `len(p)` bytes into `p`, returns how many it copied,
  and returns the error `io.EOF` ("end of file") when there is nothing
  more. An open file is a reader. So is standard input (`os.Stdin`), a
  network connection, an HTTP response body, a string wrapped with
  `strings.NewReader`, and a decompressor wrapped around any of those.
  Code written against `io.Reader` works with all of them, which is why
  `logq` will read from standard input in Step 10 with almost no new code.

  `io.ReadAll(r)` calls `Read` repeatedly, growing a byte slice, until it
  gets `io.EOF`, and returns everything it read. Reaching the end is
  success, so `ReadAll` returns a `nil` error then. `os.ReadFile(name)` does
  the open, `ReadAll` and close in one call; it is used here as three
  steps so that you see the reader.

  `ReadAll` is simple and right for small inputs: a config file, an API
  response you know is small. Its cost is that the whole input sits in
  memory at once. Step 5 measures exactly how much that costs for a big
  log, and fixes it.
]

#goconcept(title: [Bytes and strings])[
  A `[]byte` is a slice of bytes you can change; a `string` is a sequence
  of bytes you cannot. Files and networks deal in bytes, people in strings.
  `string(data)` converts bytes to a string and `[]byte(s)` goes the other
  way. Each conversion copies the data, so for a 100 MB file it costs
  another 100 MB. Go will not convert implicitly: returning `data` where a
  `string` is expected is a compile error.
]

#checkpoint(step: 4, of: 14, title: [Reading app.log])[
  You should have:

  #code(file: "logq/")[```
  logq/
  ├── app.log
  ├── go.mod
  └── main.go
  ```]

  Run it with the file name after the dot. `go run .` passes any further
  arguments to your program:

  #output("ch00/s4-run.txt")

  Line 11 is reported because its second word, `line`, is not a level.
  The errors are part of the design, so check them as well. Run without a
  file, with a file that does not exist, and from the wrong directory:

  #output("ch00/s4-errors.txt")

  The `exit status` lines come from `go run`, which reports how your
  program ended. The usage case exits with 2, the missing file with 1. The
  message `open nope.log: no such file or directory` came from `os.Open`;
  `logq` only added its name in front. The last command ran `go run` in
  your home directory, where there is no `go.mod`, so Go did not know what
  to build.

  #troubleshoot(
    ([`usage: logq FILE` and `exit status 2`], [You ran `go run .` without a file name], [`go run . app.log`]),
    ([`logq: open nope.log: no such file or directory`], [No file by that name in the current directory; often a typo, or `app.log` was never created], [`ls` to check; create `app.log` from the listing above]),
    ([`go: go.mod file not found in current directory or any parent directory`], [You ran a `go` command outside the `logq` directory], [`cd ~/logq` (or wherever you created it); `pwd` shows where you are]),
    ([`cannot use data (variable of type []byte) as string value in return statement`], [`readLog` returned the bytes without converting them], [`return string(data), nil`; see "Bytes and strings"]),
  )
]

#step(5, 14, "Streaming a big file", label: <sec-zero-s5>)

Step 4 works, but it reads the whole file into memory before looking at a
single line. Production logs are not 18 lines long; a busy service writes
gigabytes a day. This step measures what Step 4 costs on a big file, then
changes `logq` to read one line at a time, so its memory use stays the
same whatever the file's size.

Before changing any code, build the Step 4 version under a different name
so you can compare later, then make a big log. `yes` prints the same line
forever, and `head -n 2000000` keeps the first two million lines. On macOS,
`/usr/bin/time -l` runs a program and then reports what it used;
`grep -E` keeps only the lines we care about (on Linux, use
`/usr/bin/time -v` and look for "Maximum resident set size", which is in
kilobytes):

#code(file: "terminal")[```
go build -o logq-step4 .
```]

#output("ch00/s5-big.txt")

The file is 132 MB. The _maximum resident set size_, the most memory the
process held at once, is printed in bytes: 353,468,416, which is 337 MB in
the units `ls` uses, more than two and a half times the file. Look at the
code again and the reason is plain: `io.ReadAll` holds the file's
bytes, `string(data)` copies them, and `strings.Split` makes a slice of two
million strings that point into that copy. On a laptop that is slow; in a
container with a 256 MB memory limit, the kernel kills the process.

The fix is to never hold more than one line. Change the top of `main.go`,
replacing the imports (`io` goes, `bufio` arrives) and adding a constant:

#src("workbook/ch00/step5/main.go", region: "head")

Replace `run`, and delete `readLog`:

#src("workbook/ch00/step5/main.go", region: "run")

`bufio.NewScanner(f)` wraps the file in a _scanner_ that reads it in
chunks and hands out one line at a time. Each call to `scanner.Scan()`
moves to the next line and returns `true`, or returns `false` when there
are no more lines or something went wrong. `scanner.Text()` returns the
current line, without its line break. After the loop, `scanner.Err()`
says which of the two ended the loop: `nil` for the end of the file, an
error otherwise. Because the scanner counts nothing for you, `lineNo`
keeps track of line numbers.

`scanner.Buffer(...)` raises the longest line the scanner accepts. Without
it, a line longer than 64 KiB stops the scan with an error, and logs with
long lines (a stack trace on one line, a large JSON payload) are common
enough that the default is a trap. `maxLine` sets the limit at 1 MiB, and
`make([]byte, 0, 64*1024)` gives the scanner a 64 KiB buffer to start
with, which it grows only when a long line arrives.

Note the second `err` inside the loop: `level, err := parseLevel(line)`
declares a new `err` that exists only inside the loop body. It does not
replace the `err` from `os.Open`; Go calls this _shadowing_. Here it is
harmless. Step 13 shows a case where it is not.

#goconcept(title: [bufio.Scanner])[
  A `bufio.Scanner` reads from any `io.Reader` and splits the input into
  _tokens_, lines by default. The loop always has the same shape:

  #code(file: "sketch")[```go
  scanner := bufio.NewScanner(r)
  for scanner.Scan() {
  	line := scanner.Text()
  	// use line
  }
  if err := scanner.Err(); err != nil {
  	// the loop stopped early: report err
  }
  ```]

  Forgetting the `Err` check is the classic mistake: when reading fails
  halfway, `Scan` returns `false` exactly as it does at the end of the
  file, and the program carries on with half the data and no complaint. The
  checkpoint shows it happening.

  A token longer than the buffer's maximum (64 KiB unless you call
  `Buffer`) stops the scan with `bufio.ErrTooLong`, whose message is
  `bufio.Scanner: token too long`. For input with no size limit at all,
  `bufio.Reader` and its `ReadString('\n')` method handle lines of any
  length, at the cost of more code. `Scanner` also accepts other ways of
  splitting: `scanner.Split(bufio.ScanWords)` produces words.
]

#goconcept(title: [Streaming versus reading everything])[
  _Streaming_ means processing data as it arrives, a piece at a time,
  instead of loading it all first. The memory a streaming program needs
  depends on the size of one piece (here, the longest line), not on the
  size of the input. That is what lets a 10 MB program process a 50 GB
  file, or read from a source that never ends, such as a log being written
  or a network connection.

  Reading everything is fine, and simpler, when the input is small and has
  a known bound. For data that grows with traffic, users or time, stream.
  Most of Go's standard library is built for streaming: readers wrap
  readers (`gzip.NewReader(f)`, `bufio.NewScanner(r)`), so a pipeline of
  decompression, scanning and parsing still holds only a few kilobytes at
  a time.
]

#production(title: [Memory limits turn a slow tool into a dead one])[
  On a laptop, a tool that holds a whole file in memory is slow. In a
  Kubernetes pod with a memory limit, it is killed: the kernel's
  out-of-memory killer ends the process with no Go error message at all,
  and the pod shows `OOMKilled`. Log processors, backup tools and anything
  that reads uploads must stream. Chapter 5 reproduces that OOM kill in a
  container and covers the other side of the trade: buffer sizes and
  throughput.
]

#checkpoint(step: 5, of: 14, title: [Constant memory])[
  The output on `app.log` is the same as in Step 4. On the big file it is
  the same answer in a fraction of the memory. Build the new version and
  measure it:

  #output("ch00/s5-run.txt")

  About 10 MB instead of 337 MB, and that number does not grow with the
  file, because the program holds one line at a time.

  Now a log with one 100,000-byte line, longer than the
  scanner's default limit and shorter than `maxLine`. `printf` writes text
  without a line break, `head -c` takes 100,000 bytes from `/dev/zero`, and
  `tr` turns them into the letter `x`:

  #output("ch00/s5-long.txt")

  Delete the `scanner.Buffer` line and the same file fails:

  #output("ch00/s5-toolong.txt")

  That is the right behaviour for a line that really is too long: an error
  and a non-zero exit status. Now delete the `scanner.Err` check as well:

  #output("ch00/s5-noerr.txt")

  No error, exit status 0, and every count is zero. A script relying on
  this would conclude the log was empty. Put both lines back.

  #troubleshoot(
    ([`logq: bufio.Scanner: token too long`], [A line is longer than the scanner allows: 64 KiB by default], [Call `scanner.Buffer` with a larger maximum; see "bufio.Scanner"]),
    ([All counts are 0 and the exit status is 0, but the file is not empty], [Reading stopped with an error that nobody checked], [Check `scanner.Err()` after the loop]),
    ([`cannot use line (variable of type func() string) as string value`], [`line := scanner.Text` without parentheses stores the method instead of calling it], [`scanner.Text()`]),
    ([Memory still grows with file size], [Something keeps every line, such as appending lines to a slice], [Process each line inside the loop and keep only counts]),
  )
]

#step(6, 14, "Slices and maps", label: <sec-zero-s6>)

`logq` counts levels in four separate variables and passes them around as
five `int` parameters. Adding a level would mean changing code in four
places. This step replaces those variables with a _map_ from level name to
count, and remembers the numbers of the bad lines in a _slice_. The output
gains the list of bad lines; everything else stays the same.

Replace the top of `main.go`. `io` comes back, `slices` arrives, and a
package-level variable lists the known levels in order of severity:

#src("workbook/ch00/step6/main.go", region: "head")

Replace `run` and add `countLevels` after it:

#src("workbook/ch00/step6/main.go", region: "run")

`countLevels` takes an `io.Reader` rather than a file name, so it does not
care where the lines come from; `run` opens the file and passes it in.
`make(map[string]int)` creates an empty map whose keys are strings and
whose values are ints. `counts[level]++` adds one to the count for that
level; a key that is not in the map yet reads as 0, so the first `++` makes
it 1. `bad = append(bad, lineNo)` adds a line number to the end of the
slice. The function returns three results, the last of which is
`scanner.Err()`, so a read error reaches the caller.

`parseLevel` can now check the level against the `levels` slice instead
of listing the names a second time:

#src("workbook/ch00/step6/main.go", region: "parse")

And `printSummary` takes the map and the slice:

#src("workbook/ch00/step6/main.go", region: "summary")

It loops over `levels`, not over the map, so the levels always print in
the same order. Levels that never appeared print 0, because looking up a
missing key gives the zero value. `%v` prints the slice in brackets.

#goconcept(title: [Slices])[
  A slice is an ordered list of values of one type: `[]string`, `[]int`.
  It is Go's everyday list. The essentials:

  #code(file: "sketch")[```go
  levels := []string{"DEBUG", "INFO"}  // a slice literal
  levels = append(levels, "WARN")       // add to the end
  first := levels[0]                    // index from 0: "DEBUG"
  n := len(levels)                      // 3
  some := levels[1:3]                   // items 1 and 2: INFO, WARN
  var bad []int                         // nil slice: len 0, ready to append
  ```]

  `append` returns the new slice, and you must store the result:
  `bad = append(bad, n)`. A slice is a small view onto an underlying
  array; when the array is full, `append` allocates a bigger one and copies
  the items across, so the old and new slices may no longer share storage.
  Storing the result covers both cases. Indexing past the end panics, as
  Step 2 showed. `levels[1:3]` makes a new slice that shares storage with
  `levels`, which is fast but means changes through one are visible
  through the other. The `slices` package has the common operations:
  `slices.Contains`, `slices.Index`, `slices.Sort`, `slices.Equal`.

  _Coming from Python:_ a slice is like a list, but every item has the
  same type, and negative indexes do not exist. _Coming from Java:_ it is
  closer to `ArrayList` than to an array.
]

#goconcept(title: [Maps])[
  A map stores values under keys: `map[string]int` maps strings to ints.

  #code(file: "sketch")[```go
  counts := make(map[string]int)  // or: counts := map[string]int{}
  counts["ERROR"]++               // missing key reads as 0, so this is 1
  n := counts["WARN"]             // 0: WARN is not a key yet
  n, ok := counts["WARN"]         // ok is false: tells "0" from "absent"
  delete(counts, "ERROR")
  for level, n := range counts { ... } // order is NOT fixed
  ```]

  Three facts cause most map bugs. The order of `range` over a map is
  deliberately unpredictable and changes from run to run, so sort the keys
  or loop over a separate slice when order matters. A map declared with
  `var counts map[string]int` and never made is `nil`: reading from it
  works and gives zero values, but writing to it panics. And maps are not
  safe for use from several goroutines at once without a lock (Step 14).

  _Coming from Python:_ a map is a `dict`, and a missing key gives the zero
  value instead of raising `KeyError`. _Coming from Java:_ it is a
  `HashMap`, with built-in syntax.
]

#goconcept(title: [Package-level variables])[
  `var levels = []string{...}` sits outside any function, so every function
  in the package can use it. Go has no `const` slices, so a fixed list
  like this is a variable by necessity; treat it as read-only. Keep
  package-level variables rare: any function can change them, which makes
  bugs hard to trace, and they are shared by every goroutine.
]

#checkpoint(step: 6, of: 14, title: [The same counts, better types])[
  Run it. The counts match Step 5, and the bad line is listed:

  #output("ch00/s6-run.txt")

  Two map mistakes are worth seeing. Declare the map without making it,
  `var counts map[string]int`, and the first write panics. The trace shows
  the chain of calls, most recent first: the panic happened in
  `countLevels`, called by `run`, called by `main`:

  #output("ch00/s6-nilmap.txt")

  And print the counts by ranging over the map instead of over `levels`.
  Two runs of the same binary on the same file:

  #output("ch00/s6-order.txt")

  #troubleshoot(
    ([`panic: assignment to entry in nil map`], [The map was declared but never created with `make` or a literal], [`counts := make(map[string]int)`; see "Maps"]),
    ([Levels print in a different order on each run], [The loop ranges over the map, whose order is random by design], [Loop over the `levels` slice, or sort the keys]),
    ([`append(bad, lineNo) (value of type []int) is not used`], [The result of `append` was thrown away], [`bad = append(bad, lineNo)`; see "Slices"]),
    ([`panic: runtime error: index out of range [0] with length 0`], [Code read `bad[0]` on a file with no bad lines, so the slice was empty], [Check `len(bad) > 0` before indexing]),
  )
]

#step(7, 14, "Structs and methods", label: <sec-zero-s7>)

So far `logq` only looks at the second word of each line. A real query
needs every part: the time, the level, the service and the message. This
step parses each line into a _struct_, a value with named fields, and
gathers the statistics into another struct with _methods_, functions that
belong to a type. The summary also learns when the log starts and ends.

Replace the top of `main.go`; `time` joins the imports:

#src("workbook/ch00/step7/main.go", region: "head")

Keep `maxLine`, `levels` and `main` as they are. Replace `run` and
`countLevels` with a new `run` and a function called `summarize`:

#src("workbook/ch00/step7/main.go", region: "run")

`summarize` returns a `Stats` value instead of a map and a slice.
`var st Stats` creates one with every field at its zero value, `st.Bad++` adds one
to a field, and `st.Add(e)` calls the method `Add` on `st`. Back in `run`,
`st.Print()` prints it. Replace `parseLevel` with the type `Entry` and a
function that fills one in:

#src("workbook/ch00/step7/main.go", region: "entry")

`type Entry struct { ... }` defines a new type with four fields. Each
field has a name and a type, and `Time` has type `time.Time` from the
standard library, a moment in time. `strings.SplitN(line, " ", 4)` splits
at spaces into at most four parts, so the fourth part is the whole rest of
the line, spaces included: exactly what a message needs. `time.Parse`
turns the first part into a `time.Time`, or fails. The last lines build an
`Entry` with a _struct literal_, naming each field and its value.

Replace `printSummary` with the `Stats` type and its methods, and keep
`percent` at the bottom of the file:

#src("workbook/ch00/step7/main.go", region: "stats")

`func (s *Stats) Add(e Entry)` is a method: the extra parameter before the
name, `(s *Stats)`, is the _receiver_, the value the method is called on.
Inside `Add`, `s` is the `Stats` that `st.Add(e)` was called on. `Add`
makes the `Levels` map the first time it is needed, so a `Stats` declared
with `var st Stats` works without any setup. `s.First.IsZero()` reports
whether `First` still holds the zero time, meaning nothing has been seen
yet. `Print` computes the time span with `s.Last.Sub(s.First)`, which
returns a `time.Duration` that prints itself as `6m11s`.

The difference between `(s *Stats)` on `Add` and `(s Stats)` on `Print` is
the most important idea in this step.

#goconcept(title: [Structs])[
  A struct groups named fields into one value:

  #code(file: "sketch")[```go
  type Entry struct {
  	Time    time.Time
  	Level   string
  	Service string
  	Message string
  }

  e := Entry{Level: "WARN", Service: "db"} // other fields: zero values
  e.Message = "slow query"                   // set a field
  fmt.Println(e.Service)                     // read a field: db
  var z Entry                                // every field at its zero value
  ```]

  Always name the fields in a literal. `Entry{t, "WARN", "db", "slow"}`
  also compiles, but it breaks the moment someone adds or reorders a field,
  and the compiler rejects it if you leave one out.

  Assigning a struct copies all its fields: after `b := a`, changing
  `b.Level` leaves `a` alone. Two structs can be compared with `==` when all
  their fields can be, and Go gives every struct a useful zero value
  without a constructor. A common Go design goal is to make that zero value
  ready to use, as `Stats` does by making its map lazily in `Add`.

  _Coming from Java:_ a struct is a class with only fields, no inheritance
  and no constructor; plain functions called `NewX` play the constructor's
  role when one is needed. _Coming from Python:_ think of a dataclass whose
  fields are fixed at compile time.
]

#goconcept(title: [Pointers])[
  A _pointer_ holds the memory address of a value instead of the value
  itself. `&st` means "the address of `st`" and has type `*Stats`, read
  "pointer to Stats". Through a pointer you can change the original value.
  The zero value of a pointer is `nil`, pointing at nothing, and using a
  `nil` pointer to reach a field panics with the message
  `invalid memory address or nil pointer dereference`.

  You rarely write `&` and `*` for method calls, because Go inserts them:
  when `st` is a variable, `st.Add(e)` is shorthand for `(&st).Add(e)`.
  `os.Open` returning an `*os.File` in Step 4 was a pointer too: everyone
  who holds it refers to the same open file.

  _Coming from Java, Python or JavaScript:_ in those languages, objects are
  always handled through references, so assigning one variable to another
  shares the object. In Go, assignment copies, unless what you copy is a
  pointer (or a map, slice or channel, which contain pointers inside).
]

#goconcept(title: [Methods: pointer and value receivers])[
  A method is a function with a receiver. With a _value receiver_,
  `func (s Stats) Print()`, the method gets a copy of the value. With a
  _pointer receiver_, `func (s *Stats) Add(e Entry)`, it gets a pointer to
  the original. The rule is simple:

  - If the method changes the receiver, use a pointer receiver. `Add` with
    a value receiver would add to a copy that is thrown away when it
    returns; the checkpoint shows that bug.
  - If the struct is large, or holds something that must not be copied,
    use a pointer receiver even for reading.
  - Otherwise a value receiver is fine, and it tells readers the method
    does not change anything.

  In practice, once one method of a type needs a pointer receiver, most
  Go code gives all of the type's methods pointer receivers, for
  consistency. `Stats` mixes them here only to show the difference.
  Methods can be declared on any type you define in the same package, not
  just structs; Step 8 adds one to a number type.
]

#goconcept(title: [Times and durations])[
  `time.Time` is a moment, `time.Duration` a length of time (an `int64`
  count of nanoseconds that prints as `6m11s` or `1.5s`). `t2.Sub(t1)`
  gives the duration between two times, `t.Add(d)` moves a time, and
  `t1.Before(t2)` and `t1.After(t2)` compare them.

  Parsing and formatting use a _layout_: a sample of one particular moment,
  Mon Jan 2 15:04:05 MST 2006, written in the format you want. The
  numbers are 1 to 7 in order (month 1, day 2, hour 3 PM, minute 4,
  second 5, year 06, zone -7). `"2006-01-02"` means a date like
  `2026-11-03`, and `time.TimeOnly` is `"15:04:05"`. The `time` package
  has constants for the common layouts, and `time.RFC3339` is the one
  `logq` parses. Writing a layout like `YYYY-MM-DD` is the mistake everyone
  makes once.
]

#interview(title: [“When do you use a pointer receiver?”])[
  Give the rule and the reason. A method that modifies its receiver needs a
  pointer receiver, because a value receiver works on a copy. Large structs
  and structs containing a `sync.Mutex` also take pointers, to avoid
  copying. Then add the part interviewers listen for: the receiver type
  decides the _method set_. A method with a pointer receiver belongs to
  `*T`, not `T`, so only a `*T` satisfies an interface that needs it.
  That is why a type sometimes "does not implement" an interface you can
  see it implementing; Step 11 shows the exact error.
]

#checkpoint(step: 7, of: 14, title: [Entries and statistics])[
  The counts are the same, line 11 now fails on its time instead of its
  level, and the summary gains the time span of the log:

  #output("ch00/s7-run.txt")

  Change `Add` to a value receiver, `func (s Stats) Add(e Entry)`, and run
  it again. It compiles without complaint, and counts nothing:

  #output("ch00/s7-value.txt")

  Every call to `Add` changed a copy of `st` that disappeared when `Add`
  returned. Only `Bad`, which `summarize` changes directly, was counted.
  Put the `*` back.

  Now make `st` a pointer that points at nothing, `var st *Stats`. The first
  call to `Add` panics. Go traces print the arguments of each call as raw
  numbers; `cut -c1-80` trims them so the lines fit on this page:

  #output("ch00/s7-nilptr.txt")

  The receiver in the trace, `main.(*Stats).Add(0x0, ...)`, is the address
  `0x0`: a nil pointer. The panic happened at `main.go:124`, inside `Add`,
  at the first line that touched a field.

  A wrong time layout makes every line fail. With
  `time.Parse("YYYY-MM-DDThh:mm:ssZ", parts[0])` and the error returned as
  is, line 1 is reported like this, and so is every other line:

  #block(inset: (left: 10pt))[#text(size: 8.6pt)[
    `line 1: parsing time "2026-11-03T09:00:01Z" as "YYYY-MM-DDThh:mm:ssZ":`
    `cannot parse "2026-11-03T09:00:01Z" as "YYYY-MM-DDThh:mm:ssZ"`
  ]]

  #troubleshoot(
    ([All counts are 0, `bad` is right, and the span is `00:00:00`], [`Add` has a value receiver, so it changed a copy], [`func (s *Stats) Add`; see "Methods: pointer and value receivers"]),
    ([`panic: runtime error: invalid memory address or nil pointer dereference`], [A method or field was used through a `nil` pointer], [Find the `0x0` receiver in the trace; make the value with `var st Stats`]),
    ([`too few values in struct literal of type Entry`], [A literal without field names, missing a field], [Name the fields: `Entry{Time: t, Level: ...}`; see "Structs"]),
    ([`cannot parse "2026-11-03T09:00:01Z" as "YYYY-MM-DDThh:mm:ssZ"` on every line], [The time layout is not written in Go's reference-time style], [Use `time.RFC3339`; see "Times and durations"]),
  )
]

#step(8, 14, "Packages", label: <sec-zero-s8>)

`main.go` now holds two different things: the program (reading a file,
printing results) and knowledge about log lines (what a valid line is,
how to count entries). The second part is useful on its own: other tools
could parse the same format. This step moves it into a _package_ of its
own, called `logline`, and gives levels a real type.

Make a directory for the package inside `logq`, and create two files in
it. The first is `logline/logline.go`:

#src("workbook/ch00/step8/logline/logline.go")

The first line that is not a comment, `package logline`, says this file
belongs to package `logline`. The comment above it is the package's
documentation, and starts with "Package logline" by convention. Every
name that other packages use starts with a capital letter: `Level`,
`ParseLevel`, `Entry`, `Parse`. That capital letter is how Go decides what
a package _exports_.

`type Level int` defines a new type whose values are integers. The
`const` block gives four of those values names. `iota` is a counter that
starts at 0 in each `const` block and goes up by one per line, so `Debug`
is 0, `Info` 1, `Warn` 2 and `Error` 3, and the later lines repeat the
type and the `iota` implicitly. Because the levels are numbers in order of
severity, Step 10 can ask "is this level at least `Warn`?" with `>=`.

`String` is a method on `Level` that returns its name. `fmt` notices that
a type has a `String() string` method and calls it when printing, so
`fmt.Println(logline.Warn)` prints `WARN`, not `2`; Step 11 explains how
`fmt` knows. `ParseLevel` goes the other way, using `strings.EqualFold`
to compare names without regard to case, so `warn` works as well as
`WARN`.

The second file is `logline/stats.go`, holding `Stats` with `Levels` now
keyed by `Level`:

#src("workbook/ch00/step8/logline/stats.go")

Both files start with `package logline`, and `stats.go` uses `Debug`,
`Error` and `percent` from `logline.go` without importing anything: all
files in a directory are one package and share their names. `percent`
starts with a lower-case letter, so it stays private to the package.

Now `main.go` sheds everything that moved. Delete `Entry`, `parseEntry`,
`Stats` with its methods, `percent` and the `levels` variable. Replace the
top of the file:

#src("workbook/ch00/step8/main.go", region: "head")

and replace `summarize`, which now uses the package's names:

#src("workbook/ch00/step8/main.go", region: "summarize")

`main` and `run` stay as they are. The import path `logq/logline` is the
module name from `go.mod`, `logq`, followed by the directory, `logline`.
In code, you use the last part of the path as the prefix: `logline.Parse`,
`logline.Stats`.

#fig(caption: [The module after Step 8. Package `main` imports `logq/logline`; both import packages from the standard library. Arrows point from the importer to the package it uses.])[
  #diagram(
    spacing: (22pt, 16pt),
    dnode((0, 0), [`logq`\ package `main`\ `main.go`], kind: "dark"),
    dnode((1, 0), [`logq/logline`\ package `logline`\ `logline.go`, `stats.go`], kind: "accent"),
    dnode((0, 1), [`bufio`, `fmt`, `io`, `os`], kind: "muted"),
    dnode((1, 1), [`errors`, `fmt`, `strings`, `time`], kind: "muted"),
    dedge((0, 0), (1, 0), "-|>", label: [imports]),
    dedge((0, 0), (0, 1), "-|>"),
    dedge((1, 0), (1, 1), "-|>"),
  )
] <fig-zero-packages>

#goconcept(title: [Packages, modules and imports])[
  A _package_ is a directory of `.go` files that all start with the same
  `package` line; they are compiled together and share their names. A
  _module_ is a tree of packages with a `go.mod` at its root, released and
  versioned as one unit. Here the module is `logq` and holds two packages,
  `logq` (the `main` package, at the root) and `logq/logline`.

  An import path is the module path plus the directory inside the module.
  Standard library packages have short paths (`fmt`, `encoding/json`);
  packages from other modules have paths that start with a domain name,
  such as `github.com/google/go-cmp/cmp`, and `go get` downloads them and
  records the version in `go.mod`. `logq` uses only the standard library.

  Packages cannot import each other in a circle: if `logline` imported
  `logq`, the build would fail with an import cycle. That rule keeps
  dependencies pointing one way, as in @fig-zero-packages. A directory
  called `internal` is special: packages under it can only be imported by
  code in the tree rooted at `internal`'s parent, which is how larger
  projects (including this book's repository) keep packages private.
]

#goconcept(title: [Exported names])[
  A name that starts with an upper-case letter (`Parse`, `Entry`,
  `Stats.Total`) is _exported_: other packages can use it. A name that
  starts with a lower-case letter (`percent`) is visible only inside its
  own package. This applies to everything: functions, types, constants,
  variables, struct fields and methods. Go has no `public` or `private`
  keywords; the first letter is the whole mechanism.

  Export as little as you can. Every exported name is a promise to the
  code that uses it, and unexported names can be changed freely later.
  _Coming from Python:_ this is the `_name` convention, except that the
  compiler enforces it.
]

#goconcept(title: [Named types and iota])[
  `type Level int` creates a new type with `int` as its underlying type.
  A `Level` and an `int` are different types: you cannot pass a plain
  `int` where a `Level` is expected without converting it, `Level(2)`,
  which catches mixups. Named types can have methods, which is how `Level`
  gets `String`.

  `iota` numbers constants in a `const` block, starting from 0. It is Go's
  way of writing enumerations. Go does not stop someone from writing
  `Level(42)`, which is why `String` ends with a fallback that prints
  `Level(42)` rather than pretending the value is valid.
]

#checkpoint(step: 8, of: 14, title: [Two packages, same behaviour])[
  `find` lists files under the current directory; here it lists the Go
  files. The program's output is identical to Step 7, and `go vet ./...`
  checks every package in the module (`./...` means "this directory and
  everything below it"):

  #output("ch00/s8-tree.txt")

  Package mistakes produce errors that look unrelated to their cause. Here
  `Parse` was renamed to `parse` in `logline.go` and called as
  `logline.parse` from `main.go`:

  #output("ch00/s8-unexported.txt")

  From outside the package, an unexported name does not exist, so the
  compiler says `undefined` rather than "private".

  #troubleshoot(
    ([`undefined: logline.parse`], [The name starts with a lower-case letter, so it is not exported], [Rename it `Parse`; see "Exported names"]),
    ([`package logline is not in std (/usr/local/go/src/logline)`], [The import path is `"logline"`; without the module name Go looks in the standard library], [Import `"logq/logline"`: module name, then directory]),
    ([`found packages logline (logline.go) and main (stats.go) in ...`], [Files in one directory declare different packages], [Every file in `logline/` starts with `package logline`]),
    ([`./main.go:51:30: undefined: Stats`], [The type moved to `logline`, but `main.go` still uses the old name], [Add the package name: `logline.Stats`]),
  )
]

#step(9, 14, "Tests", label: <sec-zero-s9>)

Until now, you checked `logq` by running it and reading the output. That
works for 18 lines and one person. It does not work when the parser has to
handle a dozen edge cases and you change it six months from now. This step
adds _automated tests_: Go code that calls your code, checks the results,
and runs with one command, `go test`.

Tests live next to the code they test, in files whose names end in
`_test.go`. Create `logline/logline_test.go`:

#src("workbook/ch00/step9/logline/logline_test.go")

`TestParse` is a _table-driven test_, the most common shape of test in Go.
`tests` is a slice of anonymous structs, one per case, each with a name,
an input line and the expected result. The loop runs every case as a
_subtest_ with `t.Run`, so a failure names the case. For each case, the
test calls `Parse` and compares what came back with what was wanted.

`t.Fatalf` reports a failure and stops that case; `t.Errorf` reports one
and carries on, which is better when later checks still tell you
something. Both format their message like `Printf`. Comparing
`got != tt.want` works because every field of `Entry` can be compared with `==`
and both times are in UTC; Chapter 6 shows a comparison library for
cases where that is not enough. `TestParseLevel` is a smaller table that
compares only `got` and `err`, with the error case checked separately.

Create `logline/stats_test.go`, which checks `Add`, including the
promise that the zero `Stats` works:

#src("workbook/ch00/step9/logline/stats_test.go")

#goconcept(title: [Testing in Go])[
  Go's testing tools are part of the standard toolchain: no framework to
  choose, nothing to install. The rules:

  - Test files end in `_test.go`. `go build` ignores them; `go test`
    compiles them together with the package.
  - A test is a function named `TestXxx` (capital letter after `Test`)
    that takes `t *testing.T`. Other functions in the file are helpers.
  - A test passes unless it calls `t.Error`, `t.Errorf`, `t.Fatal` or
    `t.Fatalf`, or panics.
  - `go test ./...` runs every package's tests; `-v` lists each test,
    `-run` selects tests whose names match a regular expression, and
    `-cover` reports how much of the code the tests ran.

  The test file says `package logline`, so the tests can use unexported
  names such as `percent`. Go caches test results: if nothing a package's
  tests depend on has changed, `go test` prints `(cached)` and the old
  result instead of running them again. `go test -count=1` forces a run.

  _Coming from Python:_ there is no `assert`; you write the comparison
  and the message yourself, which makes failure messages clearer than
  `AssertionError`. _Coming from Java:_ no annotations, and no need for
  assertion libraries, though some teams use one.
]

#goconcept(title: [Table-driven tests and subtests])[
  A table-driven test separates the cases (data) from the checking
  (code). Adding a case is one line in the table, so it is cheap to cover
  the edge cases you find, and the loop body states the property under
  test only once. `t.Run(name, func(t *testing.T) { ... })` runs the
  function as a subtest named `TestParse/name`, with spaces turned into
  underscores; `go test -run 'TestParse/bad'` runs only the cases whose
  names start with `bad`. When a case fails, write it down as a new row
  first, watch it fail, then fix the code. That habit is the core of the
  learn, fail, fix loop this chapter runs on.
]

=== A linter: a second pair of eyes

`go vet` catches some bugs; a _linter_ catches more. The standard choice is
*golangci-lint*, which bundles dozens of checks behind one command. Install
it with Homebrew on macOS (`brew install golangci-lint`) or with the
installer on its website (golangci-lint.run) on any system, and check
with `golangci-lint --version`. Then create `.golangci.yml` in the `logq`
directory (the name starts with a dot) to choose the checks:

#src("workbook/ch00/step9/.golangci.yml")

The standard set includes `errcheck`, which finds errors you ignored, and
`staticcheck`, which finds hundreds of subtle bugs. `errorlint` matters
from Step 13. The exclusion preset allows the common, deliberate cases of
not checking an error: closing a file you only read, and printing to the
terminal. Many teams run the linter in CI on every change; you will see it
catch real bugs in Steps 12 and 13.

#checkpoint(step: 9, of: 14, title: [Tested and linted])[
  You should have:

  #output("ch00/s9-tree.txt")

  Run all the tests. The `main` package has none yet, which Go reports with
  `?`; `logline` passes:

  #output("ch00/s9-test.txt")

  `-v` shows each test and subtest as it runs:

  #output("ch00/s9-verbose.txt")

  `-cover` measures which statements the tests ran. `-coverprofile` saves
  the details to a file, and `go tool cover -func` breaks them down by
  function:

  #output("ch00/s9-cover.txt")

  `Print` and `percent` are untested because `Print` writes straight to the
  terminal, where a test cannot read it. Step 11 fixes that. Coverage is a
  map of what is untested, not a score: 100% coverage with weak checks
  proves little.

  `-run` takes a pattern, here selecting the two subtests whose names
  start with `bad`, and the linter finds nothing:

  #output("ch00/s9-run.txt")
  #output("ch00/s9-lint.txt")

  Now break `Parse` on purpose, so it stores the service name as the
  message too (`Message: parts[2]`), and run the tests:

  #output("ch00/s9-fail.txt")

  Each failure names the subtest, the test file and line, the input, and
  what came back against what was wanted. A message of `api` where
  `listening on :8080` was wanted points straight at the bug. Fix it and run the tests again.

  #troubleshoot(
    ([`?   logq [no test files]` and nothing else], [You ran `go test` in the module root, which tests only the `main` package], [`go test ./...` tests every package]),
    ([`?   logq/logline [no test files]`], [The test file's name does not end in `_test.go` (for example `logline_tests.go`)], [Rename it; see "Testing in Go"]),
    ([`--- FAIL: TestParse/info_line` with `got` and `want`], [The code under test returned something else], [Read `got` against `want`, fix the code, rerun]),
    ([A test you wrote never runs], [Its name does not start with `Test` and a capital letter (`testParse`, `Testparse`)], [Name it `TestParse`]),
    ([The shell cannot find `golangci-lint`], [The linter is not installed, or its directory is not on `PATH`], [Install it; see "What PATH is" in the setup]),
  )
]

#step(10, 14, "Flags, standard input and exit codes", label: <sec-zero-s10>)

`logq` still prints the same summary every time. A query tool needs
options: which level, which text. It should also work in a pipeline,
reading from standard input when no file is named, and report through its
exit status whether it found anything, the way `grep` does. This step adds
all three, and turns `logq` from a counter into a filter that prints the
matching lines.

The exit status follows `grep`: 0 if at least one entry matched, 1 if none
did, and 2 if something went wrong. A shell script can then write
`if logq -level error app.log > errors.txt; then alert; fi`.

Create a second log so there is more than one file to search. Save this as
`edge.log`, next to `app.log`:

#src("workbook/ch00/step10/edge.log")

Replace `main.go` completely. The top has a longer doc comment, because
the doc comment of a `main` package is the tool's manual:

#src("workbook/ch00/step10/main.go", region: "head")

`main` hands the arguments to `run` and exits with whatever status `run`
returns:

#src("workbook/ch00/step10/main.go", region: "run")

`flag.NewFlagSet` creates a set of flags.
`flags.String("level", "debug", "...")` defines a flag `-level` whose value is a string, with default
`debug` and a description for the help text, and returns a _pointer_ to
the string that will hold the value. After `flags.Parse(args)` reads the
command line, `*level` is that value. The word in backquotes in each
description becomes the name of the value in the help text.
`flags.Args()` is what is left after the flags: the file names. With none,
`run` uses `"-"`, the usual name for standard input.

`flags.Usage` is replaced with a function that prints a usage line; `flag`
calls it when the user asks for `-h` or makes a mistake. With
`ContinueOnError`, `Parse` returns an error instead of exiting, which
keeps every exit in one place. `-h` produces the error `flag.ErrHelp`,
which `run` treats as success; `errors.Is` checks which error it is
(Step 13 explains it).

The settings go into a struct, `config`, with a method that decides
whether an entry passes the filters:

#src("workbook/ch00/step10/main.go", region: "config")

`strings.Contains(e.Message, "")` is always true, so an empty `-grep`
matches every entry without a special case.

The reading moves to a new file in package `main`, `scan.go`. A package
can have as many files as you like, and splitting by topic keeps each one
readable:

#src("workbook/ch00/step10/scan.go")

`scanFile` decides where to read from and `scan` does the reading. For
the name `-`, `scanFile` passes `os.Stdin` to `scan`, which accepts any
`io.Reader`, so standard input needs no other code. Matching entries are
printed as they are found, which keeps the program streaming. Messages
about bad lines now include the file name, in the `file:line:` form that
editors and terminals recognize. `maxLine` moved here because this is
the only file that uses it. `logline` and the tests are unchanged.

#goconcept(title: [Command-line flags])[
  The `flag` package parses options of the form `-name value`,
  `-name=value` or, for booleans, just `-name`. Two dashes work too
  (`--level`). Each definition returns a pointer to where the value will
  be stored, so you read it with `*`: `*level`. You can also bind a flag to
  an existing variable with `flags.StringVar(&v, ...)`.

  Parsing stops at the first argument that is not a flag. Everything from
  there on is in `flags.Args()`, and `logq app.log -level error` treats
  `-level` and `error` as file names. Put flags first. A boolean flag must
  be set to false with `-count=false`; `-count false` would make `false`
  a file name.

  `flag.Parse()` with the package-level `flag.String` functions is
  shorter and common in small programs. A `FlagSet` created inside `run`
  is better for tools: `run` can be called from tests with any arguments,
  and Step 11 does exactly that.
]

#goconcept(title: [Functions are values])[
  In Go, a function can be stored in a variable, passed as an argument and
  returned from another function. `flags.Usage = func() { ... }` assigns a
  _function literal_ (an anonymous function) to a field. The literal uses
  `flags`, a variable from the surrounding function; a function that
  captures variables like this is a _closure_, and the variables live as
  long as the closure does. You will see function values throughout Go:
  sorting with a comparison function, HTTP handlers, and the adapter in
  Step 11.
]

#goconcept(title: [Standard input and exit status])[
  `os.Stdin` is an `*os.File`, and so an `io.Reader`. When you pipe into a
  program (`cat app.log | logq`) or redirect a file into it
  (`logq < app.log`), reading `os.Stdin` reads that data. When you run
  `logq` with no files in a terminal and type nothing, it waits for you to
  type log lines; press #kbd("Ctrl-D") to end the input or #kbd("Ctrl-C")
  to stop it.

  `os.Exit(code)` ends the program at once with that status. Call it in
  one place, `main`, and have everything else return values or errors.
  Code that calls `os.Exit` deep inside cannot be tested (the test process
  would exit) and skips every pending `defer`.
]

#production(title: [Exit codes are an API])[
  CI systems, `make`, Kubernetes probes and shell scripts read only the
  exit status. A tool that prints "error" but exits 0 lets a broken
  deploy continue; one that exits 1 for both "no matches" and "could not
  read the file" makes the caller guess. Document the codes (as the doc
  comment at the top of `main.go` does), keep them stable, and test them,
  as Step 11 does.
]

#checkpoint(step: 10, of: 14, title: [A real command-line tool])[
  From now on, build the binary and run it directly, because `go run`
  hides the exit status (see the table below). `-h` prints the help that
  `flag` generated from the definitions:

  #output("ch00/s10-build.txt")

  Filter by level, then by level and text across two files:

  #output("ch00/s10-run.txt")

  The warning about line 11 goes to standard error, so it appears among
  the results in the terminal but would not end up in a file you redirect
  to. Pipe the log in instead of naming it, and count:

  #output("ch00/s10-stdin.txt")

  And check the exit status. `$?` holds the status of the last command (on
  Windows PowerShell, `$LASTEXITCODE`):

  #output("ch00/s10-exit.txt")

  No match gives 1 and a bad flag value gives 2, as designed. Now three
  mistakes everyone makes with flags. A flag after the file name:

  #output("ch00/s10-order.txt")

  `-level` and `error` were taken as file names, so `logq` printed every
  line of `app.log` (with the file-name prefix, since it saw three files)
  and then failed to open a file called `-level`. A misspelled flag gets
  an error and the help text:

  #output("ch00/s10-unknown.txt")

  And `go run` reports your program's status but does not pass it on:

  #output("ch00/s10-gorun.txt")

  `go run` printed `exit status 2` and then exited with 1 itself.

  #troubleshoot(
    ([`logq: open -level: no such file or directory`], [A flag came after a file name, so parsing had stopped], [Flags first: `logq -level error app.log`]),
    ([`flag provided but not defined: -lvl`], [A misspelled or unknown flag], [Check `logq -h`]),
    ([`echo $?` prints 1 after `go run` when `logq` exited 2], [`go run` exits 1 whenever your program fails], [Build with `go build -o logq .` and run `./logq`]),
    ([`cannot use count (variable of type *bool) as bool value in struct literal`], [Flag functions return pointers], [Dereference: `*count`; see "Command-line flags"]),
    ([`logq` prints nothing and does not return], [No file was named, so it is waiting for standard input from the terminal], [Name a file, pipe one in, or press #kbd("Ctrl-D")]),
  )
]

#step(11, 14, "Interfaces", label: <sec-zero-s11>)

Two problems have been waiting for this step. The first is in `keep`:
every new filter adds another condition to one growing expression, and a
regular-expression filter would make it worse. The second is that `logq`
prints straight to the terminal, so no test can check its output. Both are
solved by the same Go feature, the _interface_: a type defined by what it
can do rather than what it is.

Make a directory `match` for a new package and create `match/match.go`:

#src("workbook/ch00/step11/match/match.go")

`Matcher` is an interface with one method: anything that has a method
`Match(e logline.Entry) bool` _is_ a `Matcher`. Below it are four types
that have such a method, each with a different idea of what matching
means:

- `MinLevel` is a `Level` under a new name; it matches entries at that
  level or above.
- `Contains` is a string; it matches messages that contain it.
- `Regexp` wraps a compiled regular expression from the standard
  `regexp` package. `NewRegexp` compiles the pattern and returns an error
  if it is invalid, so a typo becomes a message instead of a crash.
- `All` is a slice of matchers, and matches only if every one of them
  does. An `All` is itself a `Matcher`, so matchers combine into bigger
  ones.

None of these types says "I implement `Matcher`". Each just has the
method, and that is enough. `Func` shows a trick worth knowing: it is a
function type with a `Match` method that calls the function, so any
ordinary function of the right shape can be used where a `Matcher` is
expected. `Describe` turns any matcher into readable text with a _type
switch_, which asks which concrete type is inside an interface value.

The tests show all of them at work. Create `match/match_test.go`:

#src("workbook/ch00/step11/match/match_test.go")

The table holds values of different types (`MinLevel`, `Contains`,
`*Regexp`, a `Func`, two `All`s) in one field of type `Matcher`. The loop
calls `Match` without knowing or caring which type each one is.

Now the output. `Stats.Print` should write wherever its caller wants,
not always to the terminal. In `logline/stats.go`, add `io` to the imports:

#src("workbook/ch00/step11/logline/stats.go", region: "imports")

and replace `Print` with a version that takes an `io.Writer`:

#src("workbook/ch00/step11/logline/stats.go", region: "print")

`fmt.Fprintf(w, ...)` is `Printf` aimed at `w`. Standard output is an
`io.Writer`, and so is an in-memory `bytes.Buffer`, which is what a test
passes.

In `main.go`, the imports gain `io` and `logq/match`:

#src("workbook/ch00/step11/main.go", region: "head")

`run` now receives standard input, output and error as parameters instead
of using `os.Stdin`, `os.Stdout` and `os.Stderr` directly, and a new flag,
`-regexp`, joins the others:

#src("workbook/ch00/step11/main.go", region: "run")

`config` replaces the level and text fields with one `Matcher`, carries
the input and the two writers, and loses `keep`. `buildMatcher` turns the
flags into an `All`:

#src("workbook/ch00/step11/main.go", region: "config")

In `scan.go`, replace `scanFile` and `scan`; they read from `c.stdin`,
write to `c.out` and `c.warn`, and ask the matcher instead of `keep`:

#src("workbook/ch00/step11/scan.go", region: "scan")

Because `run` takes its input and outputs as parameters, a test can call
it like a function and inspect everything the user would see. Create
`main_test.go` in the `logq` directory:

#src("workbook/ch00/step11/main_test.go")

`strings.NewReader(testLog)` is an `io.Reader` that reads from a string,
standing in for a file or a pipe. `&stdout` is a pointer to a
`bytes.Buffer`, which collects what `run` writes. Each case checks the
exit status and the exact output, including the error cases. The exit
codes you designed in Step 10 are now tested, not just described.

#goconcept(title: [Interfaces])[
  An interface type lists methods. Any type that has all of those methods
  _satisfies_ the interface, automatically:

  #code(file: "sketch")[```go
  type Matcher interface {
  	Match(e logline.Entry) bool
  }

  type Contains string
  func (m Contains) Match(e logline.Entry) bool { ... }

  var m Matcher = Contains("timeout") // fine: Contains has Match
  m.Match(e)                          // calls Contains.Match
  ```]

  There is no `implements` keyword. This is called _implicit
  satisfaction_, and it has a big consequence: you can define an interface
  for types you did not write, in your own package, after the fact.
  `logq` could accept any type from any library that happens to have the
  right `Match` method.

  An interface value holds two things: a concrete value and its type.
  Calling a method calls the concrete type's method. The zero value of an
  interface is `nil`, with neither, and calling a method on it panics.

  Go interfaces are small. The most used ones in the standard library have
  one method: `io.Reader`, `io.Writer`, `fmt.Stringer`, `error`. A small
  interface is easy to satisfy, easy to fake in a test, and says exactly
  what a function needs. The Go proverb is "the bigger the interface, the
  weaker the abstraction". A related habit: functions _accept_ interfaces
  (`countLevels(r io.Reader)`) and _return_ concrete types
  (`NewRegexp` returns `*Regexp`).

  _Coming from Java or C\#:_ the same idea without the declaration, so
  interfaces are usually defined by the code that _uses_ them, not by the
  code that implements them. _Coming from Python:_ this is duck typing,
  checked by the compiler.
]

#goconcept(title: [io.Writer, and the interfaces you have already used])[
  `io.Writer` is the mirror of `io.Reader`:

  #code(file: "the io package")[```go
  type Writer interface {
  	Write(p []byte) (n int, err error)
  }
  ```]

  Files (including `os.Stdout` and `os.Stderr`), network connections,
  HTTP response writers, `bytes.Buffer`, `strings.Builder`, hash functions
  and compressors are all writers. Write your output code against
  `io.Writer` and the caller chooses the destination: the terminal in
  production, a buffer in a test, a gzip file in a backup job.

  You met two other interfaces before this step without being told. Any
  type with a `String() string` method satisfies `fmt.Stringer`, and `fmt`
  checks for it when printing: that is how `Level` printed as `WARN` in
  Step 8. And `error` is an interface too, built into the language:

  #code(file: "the language")[```go
  type error interface {
  	Error() string
  }
  ```]

  Any type with an `Error() string` method is an error. Step 13 makes one.
]

#goconcept(title: [Type assertions and type switches])[
  An interface value hides its concrete type, but you can ask for it. A
  _type assertion_ `m.(Contains)` returns the `Contains` inside `m`, and
  panics if `m` holds something else; the two-result form
  `c, ok := m.(Contains)` sets `ok` to `false` instead of panicking. A
  _type switch_ tries several types in turn:

  #code(file: "sketch")[```go
  switch m := m.(type) {
  case Contains:   // here m is a Contains
  case *Regexp:    // here m is a *Regexp
  default:         // any other type; m is still a Matcher
  }
  ```]

  Use them sparingly. `Describe` works because every matcher type lives in
  the same package as `Describe`, so the list of cases can be kept
  complete. If other packages could add matchers, a method on the
  interface (say, `Describe() string` in `Matcher`) would be the better
  design: each type would describe itself, and nothing would need updating
  when a new one appears. For errors, which are often wrapped inside other
  errors, use `errors.As` instead of a type switch (Step 13).
]

=== Interfaces make designs possible

The matcher types are a small example of patterns that run through every
large Go code base, including the projects later in this book. @fig-zero-matcher
shows them.

#fig(caption: [The `Matcher` design. Each concrete type is one strategy; `All` combines matchers; `Func` adapts a plain function; `Not`, which you add in Exercise 0.5, wraps one matcher to change its behaviour.])[
  #diagram(
    spacing: (18pt, 18pt),
    dnode((2, 0), [`Matcher` interface\ `Match(Entry) bool`], kind: "dark"),
    dnode((0, 1), [`MinLevel`\ strategy], kind: "accent"),
    dnode((1, 1), [`Contains`\ strategy], kind: "accent"),
    dnode((2, 1), [`*Regexp`\ strategy], kind: "accent"),
    dnode((3, 1), [`All`\ composite], kind: "good"),
    dnode((4, 1), [`Func`\ adapter], kind: "default"),
    dnode((3, 2), [any matchers,\ including other `All`s], kind: "muted"),
    dnode((4, 2), [`func(Entry) bool`], kind: "muted"),
    dedge((0, 1), (2, 0), "-|>"),
    dedge((1, 1), (2, 0), "-|>"),
    dedge((2, 1), (2, 0), "-|>"),
    dedge((3, 1), (2, 0), "-|>"),
    dedge((4, 1), (2, 0), "-|>"),
    dedge((3, 1), (3, 2), "--|>", label: [holds]),
    dedge((4, 1), (4, 2), "--|>", label: [wraps]),
  )
] <fig-zero-matcher>

- *Strategy.* Code that needs a decision takes an interface, and each
  implementation is one way of deciding. `scan` never changes when a new
  kind of filter arrives.
- *Composite.* `All` is a `Matcher` made of `Matcher`s, so a query of any
  size is one value. The same idea gives you `io.MultiWriter`, which
  writes to several writers at once.
- *Adapter.* `Func` turns a function into an interface value. The
  standard library's `http.HandlerFunc` is exactly this, and you will use
  it in every HTTP chapter.
- *Decorator.* A type that wraps a value of an interface and is itself
  that interface can add behaviour around it: `bufio.NewWriter(w)` adds
  buffering to any writer, `gzip.NewReader(r)` decompression to any
  reader. Exercise 0.5 builds `Not`, which wraps a matcher.

None of these needs a framework or an inheritance hierarchy: one small
interface and a few types are enough.

#interview(title: [“How are Go interfaces different from Java's?”])[
  Satisfaction is implicit: a type implements an interface by having its
  methods, with no declaration. So interfaces are defined where they are
  consumed, kept small (often one method), and libraries return concrete
  types. Mention the method-set rule (a pointer-receiver method belongs to
  `*T` only) and the nil trap: an interface holding a nil pointer is not a
  nil interface, so `err != nil` can be true for a "nil" `*MyError`.
  Strong answers name `io.Reader`/`io.Writer` composition as the example
  that shows why the design works.
]

#checkpoint(step: 11, of: 14, title: [Tested end to end])[
  You should have three packages, each with tests:

  #code(file: "logq/")[```
  logq/
  ├── .golangci.yml   app.log   edge.log   go.mod
  ├── main.go   main_test.go   scan.go
  ├── logline/
  │   ├── logline.go   logline_test.go   stats.go   stats_test.go
  └── match/
      ├── match.go   match_test.go
  ```]

  All three packages pass, including `logq` itself, which now has tests:

  #output("ch00/s11-test.txt")

  The new flag and the query description in action. Note that the tool
  reports a bad pattern as an error rather than crashing:

  #output("ch00/s11-run.txt")

  The two interface errors you will meet most often both come with
  explanations. Append `*re` (a `Regexp` value) instead of `re` (a
  pointer) to the `All`:

  #output("ch00/s11-ptrrecv.txt")

  `Match` has a pointer receiver, so only `*Regexp` has that method; a
  `Regexp` value does not satisfy `Matcher`. And give `Contains.Match` the
  wrong parameter type, `message string`:

  #output("ch00/s11-signature.txt")

  The compiler found the problem in `Describe`'s type switch first, and
  printed the method it has against the method `Matcher` wants. Wherever
  the mismatch is found, those `have` and `want` lines are the clue.

  #troubleshoot(
    ([`match.Regexp does not implement match.Matcher (method Match has pointer receiver)`], [A value was used where only a pointer has the method], [Use the pointer `NewRegexp` returns; see the interview box in Step 7]),
    ([`wrong type for method Match` with `have` and `want` lines], [The method's signature differs from the interface's], [Make the parameters and results match exactly]),
    ([`panic: runtime error: invalid memory address or nil pointer dereference` in `main.config.scan`], [`c.match` is a nil interface: here `buildMatcher` returned `nil, nil` when no flags were set], [Never return a nil interface for "match everything"; return an empty `match.All{}`]),
    ([`bytes.Buffer does not implement io.Writer (method Write has pointer receiver)`], [A test passed `stdout` instead of `&stdout`], [Pass the buffer's address: `&stdout`]),
  )
]

#step(12, 14, "JSON output and generics", label: <sec-zero-s12>)

Two features finish the query side of `logq`. `-json` prints matching
entries as JSON, the format other programs (`jq`, log shippers, a script
in another language) read most easily. `-top N` ranks the services that
logged the most matching entries, which is the first question in most
incidents: who is noisy? The ranking is written once as a _generic_
function that works for any kind of key.

In `logline/logline.go`, add _struct tags_ to `Entry`:

#src("workbook/ch00/step12/logline/logline.go", region: "entry")

and add a `MarshalText` method for `Level` after `ParseLevel`:

#src("workbook/ch00/step12/logline/logline.go", region: "marshal")

A struct tag is the text in backquotes after a field's type. Go ignores
it, but packages can read it: `json:"level"` tells `encoding/json` to call
the field `level` in JSON. Without `MarshalText`, `encoding/json` would
write a `Level` as its underlying number, `3`. With it, `encoding/json`
notices that `Level` has the method (it checks for the
`encoding.TextMarshaler` interface) and writes the name instead.

`Stats` gains a count per service. In `logline/stats.go`, replace the
`Stats` type and `Add`:

#src("workbook/ch00/step12/logline/stats.go", region: "stats")

Now the ranking. Make a directory `rank` and create `rank/rank.go`:

#src("workbook/ch00/step12/rank/rank.go")

`Top[K cmp.Ordered]` declares a _type parameter_ named `K`. Inside the
function, `K` stands for whatever key type the caller's map has, and
`cmp.Ordered` is a _constraint_ saying which types are allowed: those that
can be compared with `<`, such as numbers and strings. `Count[K any]` is a
generic struct: a key of type `K` and a number. `slices.SortFunc` sorts
with a comparison function that returns a negative number, zero or a
positive number, which `cmp.Compare` produces; sorting by count first and
key second makes the order the same on every run, even though the map's
order is random. The tests use `Top` with two different key types:

#src("workbook/ch00/step12/rank/rank_test.go")

`Top(counts, 3)` does not say what `K` is; the compiler works it out from
the map's type, string in the first test and `logline.Level` in the
second.

In `main.go`, import the new package:

#src("workbook/ch00/step12/main.go", region: "head")

and replace `run`, which gains two flags and prints the ranking:

#src("workbook/ch00/step12/main.go", region: "run")

The variable for `-json` is called `asJSON`, so that nobody reading the
code mistakes it for the `json` package, which `scan.go` imports. `config` gets the two settings and a
method that says whether entries are printed at all:

#src("workbook/ch00/step12/main.go", region: "config")

In `scan.go`, import `encoding/json`:

#src("workbook/ch00/step12/scan.go", region: "imports")

and replace `scan`. A `switch` with no value chooses how to print each
entry:

#src("workbook/ch00/step12/scan.go", region: "scan")

`json.NewEncoder(c.out)` makes an encoder that writes to any
`io.Writer`, and `enc.Encode(e)` writes `e` as one line of JSON. Writing
can fail (a closed pipe, a full disk), so the error is checked. Finally,
add two cases to the table in `main_test.go`, so `TestRun` reads:

#src("workbook/ch00/step12/main_test.go", region: "test")

#goconcept(title: [JSON and struct tags])[
  `encoding/json` converts between Go values and JSON. `json.Marshal(v)`
  returns the JSON bytes for `v`; `json.Unmarshal(data, &v)` fills `v` from
  JSON (note the `&`: it must change `v`). `json.NewEncoder(w).Encode(v)`
  and `json.NewDecoder(r).Decode(&v)` do the same over streams.

  Only exported fields are encoded; a lower-case field is invisible to the
  package, silently. Tags control the details:

  #code(file: "sketch")[```go
  type Entry struct {
  	Time    time.Time `json:"time"`              // key "time"
  	Service string    `json:"service,omitempty"` // left out when ""
  	Secret  string    `json:"-"`                 // never encoded
  }
  ```]

  `time.Time` encodes as an RFC 3339 string. A type can control its own
  encoding by implementing `json.Marshaler` (`MarshalJSON`) or
  `encoding.TextMarshaler` (`MarshalText`, used for types that are naturally
  a string, like `Level`). Decoding uses the matching `UnmarshalJSON` and
  `UnmarshalText` methods. `go vet` checks that tags are well formed.
]

#newingo("1.27", title: [encoding/json runs on the new v2 implementation])[
  Go 1.27 adds `encoding/json/v2` and `encoding/json/jsontext`, and the
  familiar `encoding/json` is now implemented on top of v2. Its behaviour
  is unchanged and decoding is faster, but the exact text of some error
  messages may differ from older Go versions. The v2 package has stricter
  defaults, such as rejecting duplicate keys in an object. `logq` keeps to
  `encoding/json`, which most code still uses.
]

#goconcept(title: [Generics])[
  A _generic_ function or type has _type parameters_, listed in square
  brackets, that the caller fills in. One definition then works for many
  types while the compiler still checks every use:

  #code(file: "sketch")[```go
  func Top[K cmp.Ordered](counts map[K]int, n int) []Count[K]

  rank.Top(map[string]int{"api": 9}, 3)       // K is string
  rank.Top(map[logline.Level]int{...}, 3)     // K is logline.Level
  ```]

  A _constraint_ says what a type parameter must support. `any` allows
  every type but lets you do almost nothing with the values. `comparable`
  allows types that work with `==` (needed for map keys). `cmp.Ordered`
  allows types that work with `<`: integers, floats and strings, and named
  types built on them, like `Level`. You can write your own constraints as
  interfaces.

  Reach for generics when the same code would otherwise be copied for
  several types: containers, sorting and ranking, `slices` and `maps`
  helpers. Do not reach for them when an ordinary interface does the job;
  `Matcher` is not generic, because each matcher behaves differently, not
  the same way on different types.
]

#newingo("1.27", title: [Generic methods])[
  Until Go 1.26, only functions and types could have type parameters;
  methods could only use the type parameters of their type. Go 1.27 lets a
  method declare its own, so `(*Rand).N[Int intType](n Int) Int` now sits
  next to the function `rand.N`. Interface methods still cannot have type
  parameters. Chapter 2 uses generic methods in API design.
]

#checkpoint(step: 12, of: 14, title: [JSON and rankings])[
  Build, print one entry as JSON (the warning about line 11 still goes to
  standard error), and rank the services across both logs:

  #output("ch00/s12-json.txt", size: 6.2pt)
  #output("ch00/s12-top.txt")

  The `level` field reads `ERROR` because of `MarshalText`. Delete that
  method and the same command prints the number:

  #output("ch00/s12-nomarshal.txt", size: 6.6pt)

  Rename the `Service` field to `service`, lower case, and it disappears
  from the JSON without a word from the compiler, because `encoding/json`
  cannot see unexported fields:

  #output("ch00/s12-lower.txt", size: 6.6pt)

  And ignore the error from `Encode`, writing just `enc.Encode(e)`. It
  compiles, `go vet` is silent, and the linter catches it:

  #output("ch00/s12-errcheck.txt")

  The last mistake is with generics. Try to rank minutes with `rank.Top`
  on a `map[time.Time]int` and the build fails with
  `time.Time does not satisfy cmp.Ordered`, followed by the list of types that would: a time
  cannot be compared with `<`. Exercise 0.9 solves that with a comparison
  function.

  #troubleshoot(
    ([`"level":3` in the JSON], [`Level` has no `MarshalText` method, so it is encoded as a number], [Add `MarshalText`; see "JSON and struct tags"]),
    ([A field is missing from the JSON], [The field is unexported (lower case)], [Capitalize it and give it a tag]),
    ([`struct field tag ... not compatible with reflect.StructTag.Get: bad syntax for struct tag value`], [A tag is malformed, such as a missing closing quote: `json:"service`], [Write tags as `json:"name"`; run `go vet`]),
    ([`Error return value of enc.Encode is not checked (errcheck)`], [The error from writing JSON is ignored], [`if err := enc.Encode(e); err != nil { return err }`]),
    ([`time.Time does not satisfy cmp.Ordered`], [The key type cannot be compared with `<`], [Use keys that can (strings, numbers), or a comparison function; see Exercise 0.9]),
  )
]

#step(13, 14, "Errors that explain themselves", label: <sec-zero-s13>)

When `logq` fails, it says what happened:
`open nope.log: no such file or directory`. A good tool also says what to do about it, and lets its callers
tell kinds of failure apart. This step adds context to errors as they
travel up, gives parse errors their own type, and makes `main` recognize
the failures it knows and print a hint. It also adds `-strict`, which
turns a bad line from a warning into an error, for CI jobs that check
logs.

In `logline/logline.go`, replace `Parse` so every failure returns a
`*ParseError`, and add the type itself at the end of the file. The
`errors` import is no longer needed; remove it:

#src("workbook/ch00/step13/logline/logline.go", region: "entry")
#src("workbook/ch00/step13/logline/logline.go", region: "parseerror")

`ParseError` is an ordinary struct. Its `Error` method, with a pointer
receiver, makes `*ParseError` satisfy the `error` interface, so `Parse`
can return `&ParseError{...}` as its `error` result. The error carries
data, which field was wrong and what was there, that a caller can use
without parsing the message.

`TestParse` now checks which field failed. In
`logline/logline_test.go`, add `errors` to the imports:

#src("workbook/ch00/step13/logline/logline_test.go", region: "imports")

and replace `TestParse`:

#src("workbook/ch00/step13/logline/logline_test.go", region: "parse")

`errors.As(err, &perr)` looks for a `*ParseError` in `err` and, if it finds
one, stores it in `perr` and returns `true`.

In `scan.go`, replace `scan`. Errors get the file name and line number
added with `fmt.Errorf` and the `%w` verb, and `-strict` returns the
first one instead of printing it:

#src("workbook/ch00/step13/scan.go", region: "scan")

In `main.go`, the imports gain `bufio` and `io/fs`:

#src("workbook/ch00/step13/main.go", region: "head")

`run` gets the `-strict` flag and sends scan errors to `explain`:

#src("workbook/ch00/step13/main.go", region: "run")

`config` gets the `strict` field:

#src("workbook/ch00/step13/main.go", region: "config")

and `explain`, with its table of hints, goes at the end of the file:

#src("workbook/ch00/step13/main.go", region: "explain")

`errors.Is(err, fs.ErrNotExist)` asks "is this, or anything it wraps, the
not-exist error?". `os.Open` returns an error that wraps the operating
system's own code, and that code counts as `fs.ErrNotExist`, so this works
on every operating system. `errors.Is(err, bufio.ErrTooLong)` recognizes
the scanner's error, even though `scan` wrapped it with a file name.
`errors.As` finds the `*ParseError` and uses its `Field` to choose a hint.

Two new tests in `main_test.go` cover `-strict` and a missing file:

#src("workbook/ch00/step13/main_test.go", region: "strict")

#goconcept(title: [Wrapping errors with %w])[
  An error message should say what failed, in terms the reader knows. The
  `os.Open` error knows the file name but not the line; `scan` knows the
  line. Each layer adds what it knows:

  #code(file: "sketch")[```go
  err = fmt.Errorf("%s:%d: %w", name, lineNo, err)
  // app.log:11: bad time "this"
  ```]

  The `%w` verb formats the error like `%v` and also _wraps_ it: the new
  error remembers the old one, and `errors.Unwrap` can get it back. A chain
  of wrapped errors reads left to right from the outermost context to the
  original cause. Use `%v` instead of `%w` when you deliberately want to
  hide the cause from callers, for example to avoid making an internal
  detail part of your API.
]

#goconcept(title: [errors.Is and errors.As])[
  Once errors are wrapped, `==` stops working: `err == bufio.ErrTooLong` is
  false when `err` is `app.log:7: bufio.Scanner: token too long`. The
  `errors` package looks through the chain for you:

  - `errors.Is(err, target)` reports whether `err` or anything it wraps is
    `target`. Use it for _sentinel errors_: fixed values such as
    `io.EOF`, `fs.ErrNotExist` and `bufio.ErrTooLong` that a package
    exports for comparison.
  - `errors.As(err, &target)` finds the first error in the chain whose type
    matches `target`'s type, stores it in `target` and returns `true`. Use
    it for error types that carry data, like `*ParseError` or the
    standard library's `*fs.PathError`. The second argument must be a
    pointer to a variable of that type: `&perr`, not `perr`.

  Since Go 1.26 there is also a generic form that needs no variable:
  `perr, ok := errors.AsType[*ParseError](err)`. This chapter uses
  `errors.As`, which you will see in most existing code; Chapter 3 uses
  both.

  _Coming from Java or Python:_ `errors.Is` and `errors.As` are what
  `catch (FileNotFoundException e)` and `except ValueError as e` do, as
  ordinary function calls.
]

#goconcept(title: [Your own error types])[
  Any type with an `Error() string` method is an error. Give it a pointer
  receiver and return a pointer, `&ParseError{...}`, so that each error is
  one value that `errors.As` can find. Make a custom type only when callers
  need data from the error; for a fixed message, `errors.New` at package
  level makes a sentinel (`var ErrEmpty = errors.New("empty log")`), and
  for everything else `fmt.Errorf` is enough.

  One trap catches everyone once. A function whose result type is `error`
  must return a literal `nil` on success, never a typed pointer that
  happens to be nil:

  #code(file: "sketch")[```go
  var perr *ParseError    // nil pointer
  return perr             // an error interface holding (*ParseError, nil):
                          // the caller's err != nil is TRUE
  ```]

  An interface is `nil` only when it holds no type at all, as the box on
  interfaces in Step 11 explained.
]

=== When err is not the err you think

Step 5 showed shadowing: `:=` inside a block declares a new variable even
if one with the same name exists outside. With errors it causes a bug the
compiler cannot see. Suppose the loop in `run` were written like this:

#code(file: "main.go (wrong)")[```go
var st logline.Stats
for _, name := range files {
	err := c.scanFile(name, &st) // a NEW err, local to the loop
	if err != nil {
		break
	}
}
if err != nil { // the err from buildMatcher, still nil
	explain(stderr, err)
	return 2
}
```]

The `err` inside the loop is a new variable. `break` leaves the loop, the
inner `err` disappears, and the check after the loop looks at the outer
`err`, left over from `buildMatcher` and `nil`. The checkpoint shows the
result: a missing file, no message, and exit status 1 for "no matches".
Write `err = ...` to assign to the outer variable, or, better, handle the
error inside the loop as the real code does.

#checkpoint(step: 13, of: 14, title: [Errors with context and hints])[
  `-strict` stops at line 11, after printing the ten good lines before it,
  and the exit status says the input was bad. A missing file gets a hint:

  #output("ch00/s13-run.txt")

  A line too long for the scanner is recognized through two layers of
  wrapping. `huge.log` holds one 2 MB line, made like `long.log` in Step 5:

  #output("ch00/s13-toolong.txt")
  #output("ch00/s13-test.txt")

  Comparing a wrapped error with `==` compiles, runs, and quietly never
  matches: the hint disappears. The `errorlint` linter you enabled in Step
  9 catches it:

  #output("ch00/s13-equal.txt")

  Formatting the error with `%v` instead of `%w` breaks the chain the same
  way: the parse error loses its hint, and the linter points at the verb.

  #output("ch00/s13-percentv.txt")

  A type switch on the error has the same problem, because the outer error
  is a wrapper, not a `*ParseError`:

  #output("ch00/s13-typeswitch.txt")

  The shadowed `err` from the box above, on a missing file:

  #output("ch00/s13-shadow.txt")

  #troubleshoot(
    ([A hint never appears; the linter says `comparing with == will fail on wrapped errors`], [`err == bufio.ErrTooLong` on a wrapped error], [`errors.Is(err, bufio.ErrTooLong)`; see "errors.Is and errors.As"]),
    ([A hint never appears; the linter says `non-wrapping format verb for fmt.Errorf`], [The error was wrapped with `%v`, which keeps the text and drops the chain], [Use `%w`; see "Wrapping errors with %w"]),
    ([`second argument to errors.As must be a non-nil pointer ...` from `go vet`], [`errors.As(err, perr)` instead of `errors.As(err, &perr)`], [Pass the address of the variable]),
    ([`type switch on error will fail on wrapped errors`], [A `switch err.(type)` on an error that may be wrapped], [`errors.As` for each type]),
    ([A missing file produces no message and exit status 1], [A shadowed `err` inside the loop; the check after it sees a different, nil `err`], [Handle the error inside the loop, or assign with `=`; see "When err is not the err you think"]),
  )
]

#step(14, 14, "Many files at once", label: <sec-zero-s14>)

Incidents rarely involve one log. A node has a log per service, a
deployment one per pod, and an archive one per hour. `logq` reads files one
after another, so ten files take ten times as long as one, even on a
machine with ten idle processor cores. This last step scans several files
at the same time with _goroutines_, collects their results through a
_channel_, and keeps the output in command-line order so it is the same on
every run.

#fig(caption: [How Step 14 scans files concurrently. At most `-j` goroutines scan at once; each sends its result on a channel; `scanAll` puts results back in command-line order; `run` prints them and merges the statistics.])[
  #diagram(
    spacing: (16pt, 12pt),
    dnode((0, 1), [`scanAll`\ starts one goroutine\ per file], kind: "dark"),
    dnode((1, 0), [scan `app.log`], kind: "accent"),
    dnode((1, 1), [scan `edge.log`], kind: "accent"),
    dnode((1, 2), [scan `db.log`\ (waits for a slot)], kind: "muted"),
    dnode((2, 1), [`results`\ channel], kind: "default"),
    dnode((3, 1), [`ordered[r.index] = r`\ then print in order,\ `Merge` the stats], kind: "good"),
    dedge((0, 1), (1, 0), "-|>"),
    dedge((0, 1), (1, 1), "-|>"),
    dedge((0, 1), (1, 2), "-|>"),
    dedge((1, 0), (2, 1), "-|>"),
    dedge((1, 1), (2, 1), "-|>"),
    dedge((1, 2), (2, 1), "-|>"),
    dedge((2, 1), (3, 1), "-|>"),
  )
] <fig-zero-fanout>

Files scanned at the same time must not write to the terminal at the same
time, or their lines would interleave unpredictably. So each file writes
into buffers of its own, and `run` prints the buffers in order after all
scans finish. (Tools such as `ripgrep` do the same.) The cost is that a
file's output appears only after the whole batch is scanned, and matching
lines are held in memory until then; Chapter 4 shows designs that stream
results in order as they complete.

In `logline/stats.go`, `Add` now calls a helper to make the maps, so that
a new method, `Merge`, can share it. Replace `Stats` and `Add`:

#src("workbook/ch00/step14/logline/stats.go", region: "stats")

and add `Merge` and `init` after them:

#src("workbook/ch00/step14/logline/stats.go", region: "merge")

Add a test for `Merge` to `logline/stats_test.go`:

#src("workbook/ch00/step14/logline/stats_test.go", region: "merge")

In `scan.go`, the imports gain `bytes` and `sync`:

#src("workbook/ch00/step14/scan.go", region: "imports")

Add a `result` type and `scanOne` before `scanFile`:

#src("workbook/ch00/step14/scan.go", region: "result")

`scanOne` makes a copy of the configuration, `fc := c`, and points the
copy's `out` and `warn` at the result's buffers. Copying a struct copies
its fields, so the original `c` still writes to the terminal and each
file's copy writes to its own buffers. `scanFile` and `scan` are not
changed at all: they write to whatever `io.Writer` they are given. That is
the payoff of Step 11.

Then add `scanAll`, the concurrent part:

#src("workbook/ch00/step14/scan.go", region: "scanall")

Read it slowly; every line matters.

- `results := make(chan *result)` makes a channel that carries pointers to
  results from the scanning goroutines to this function.
- `slots := make(chan struct{}, c.jobs)` makes a channel with room for
  `c.jobs` values. It is used as a counter of running scans: a goroutine
  puts a value in before it starts scanning, and takes one out when it
  finishes. When the channel is full, the next goroutine waits. That caps
  the number of files open at once.
- `wg.Go(func() { ... })` starts the function in a new goroutine and adds
  it to the `WaitGroup`, which counts goroutines that have not finished.
  The loop starts one goroutine per file and does not wait for any of them.
- Each goroutine scans its file, records its position in `r.index`, and
  sends the result with `results <- r`.
- A separate goroutine waits until every scanning goroutine has finished
  (`wg.Wait()`) and then closes the channel, which tells the receiving
  loop that no more results will come.
- `for r := range results` receives results in the order they finish and
  stores each at its position, so `ordered` ends up in command-line order.

`run` in `main.go` gains the `-j` flag, checks it, and replaces the loop
over files with a loop over results:

#src("workbook/ch00/step14/main.go", region: "run")

`config` gets the `jobs` field:

#src("workbook/ch00/step14/main.go", region: "config")

Finally, a test that scans 20 files three at a time and checks that the
output is in command-line order. It writes the files into
`t.TempDir()`, a directory that is deleted when the test ends. Add `fmt`,
`os` and `path/filepath` to the imports of `main_test.go`:

#src("workbook/ch00/step14/main_test.go", region: "imports")
#src("workbook/ch00/step14/main_test.go", region: "many")

#goconcept(title: [Goroutines])[
  A goroutine is a function running independently of the code that started
  it. `go f()` starts `f` in a new goroutine and returns immediately; the
  program does not wait for it. Goroutines are cheap, a few kilobytes
  each, and the Go runtime spreads them over the processor cores, so a
  program can run thousands.

  Because the starting code does not wait, every goroutine needs an owner
  that does. When `main` returns, the program exits, and any goroutines
  still running are stopped mid-work. The rule this book follows
  everywhere: a function that starts goroutines waits for them to finish
  before it returns. `scanAll` keeps it.

  Since Go 1.22, each pass of a `for` loop has its own copy of the loop
  variables, so the closures in `scanAll` each see their own `i` and
  `name`. Older code copies them first (`name := name`); you may still see
  that line in tutorials.
]

#goconcept(title: [Channels])[
  A channel is a typed pipe between goroutines. `ch <- v` sends `v`, and
  `v := <-ch` receives a value. An _unbuffered_ channel,
  `make(chan T)`, makes the sender wait until a receiver takes the value,
  so each send is also a meeting point. A _buffered_ channel,
  `make(chan T, n)`, holds up to `n` values, and a sender waits only when
  it is full; that is what makes `slots` a limit.

  `close(ch)` says no more values will be sent. Receivers can still drain
  what is left, and `for v := range ch` ends when the channel is closed and
  empty. Only a sender closes a channel, and only once; sending on a
  closed channel panics. When several goroutines send, none of them can
  know it is the last, so a coordinator closes the channel after all of
  them finish, which is the job of the goroutine that runs `wg.Wait()`.

  If every goroutine is waiting on a channel that nobody will ever use
  again, the runtime notices and stops the program with
  `fatal error: all goroutines are asleep - deadlock!`. The checkpoint shows that happening.
]

#goconcept(title: [sync.WaitGroup])[
  A `WaitGroup` counts goroutines that have not finished. `wg.Wait()`
  blocks until the count is zero. Older code calls `wg.Add(1)` before each
  `go` statement and `wg.Done()` at the end of the goroutine; `wg.Go(f)`
  does all three in one call.
]

#newingo("1.25", title: [WaitGroup.Go])[
  `wg.Go(f)` was added in Go 1.25. It removes the classic bug of calling
  `wg.Add(1)` inside the goroutine, where it can run after `wg.Wait()` has
  already returned. On older Go versions, write `wg.Add(1)` before
  `go func() { defer wg.Done(); ... }()`.
]

#goconcept(title: [Data races and the race detector])[
  A _data race_ happens when two goroutines access the same variable at
  the same time and at least one of them writes. The result is undefined:
  lost updates, corrupted slices and maps, crashes, or nothing visible
  until production load. Go's maps detect some concurrent writes and crash
  on purpose, but most races are silent.

  `scanAll` avoids shared writes by design: each goroutine writes only to
  its own `result`, and only the receiving loop writes to `ordered`. When
  goroutines must share a variable, protect it with a `sync.Mutex` or pass
  the value through a channel instead.

  The _race detector_ finds races while the program runs. Add `-race` to
  `go test`, `go run` or `go build`; the program runs slower and reports
  every race it observes, with the stack of both goroutines. It only finds
  races that actually happen during that run, so run your tests with
  `-race` routinely, as this book's repository does in CI.
]

#production(title: [Why the limit on open files matters])[
  Every open file uses a _file descriptor_, and the operating system
  limits how many one process may hold. There are two limits: a _soft_
  limit, which a process may raise itself, and a _hard_ ceiling above it.
  Go programs raise their soft limit to the hard limit when they start, but
  the hard limit still applies, and on servers and in containers it varies
  from a few thousand upwards. A tool that opens every file at once works
  on your test directory of 20 logs and fails on the server with 50,000.
  Bound concurrency by what the resource can take, not by how many items
  there are. Chapter 4 covers three ways of bounding concurrency and when
  each fits.
]

#checkpoint(step: 14, of: 14, title: [The finished tool])[
  The whole module, as it should be now:

  #code(file: "logq/")[```
  logq/
  ├── .golangci.yml   app.log   edge.log   go.mod
  ├── main.go   main_test.go   scan.go
  ├── logline/
  │   ├── logline.go   logline_test.go   stats.go   stats_test.go
  ├── match/
  │   ├── match.go   match_test.go
  └── rank/
      ├── rank.go   rank_test.go
  ```]

  Run the tests with the race detector. Every package passes, including the
  20-file test that exercises the goroutines:

  #output("ch00/s14-test.txt")

  The output looks like Step 13's, in the same order on every run:

  #output("ch00/s14-run.txt")

  To see the speed-up, eight 132 MB copies of the big log from Step 5 (made
  the same way, in a directory called `logs`), scanned with one goroutine
  at a time and then with eight. `/usr/bin/time` without `-l` prints only
  the times:

  #output("ch00/s14-speed.txt")

  The wall-clock time (`real`) dropped by about a third on the machine
  used for this book, which was busy with other work at the time. The
  `user` time, the CPU used on all cores together, went up: the cores did
  the same work in parallel, plus the cost of coordinating. Your numbers
  will differ; on an idle machine with eight cores the gain is larger.

  Now the three classic concurrency bugs. First a data race: a version of
  `scanAll` that has each goroutine `append` its result to a shared slice
  instead of sending it on a channel. A normal build seems to work. A
  build with `-race` reports the problem:

  #output("ch00/s14-race.txt")

  Both goroutines touched the same memory at `scan.go:56`, the `append`
  line: goroutine 7 read the slice after goroutine 8 had written it, with
  nothing to order the two. The report names both goroutines and where
  they were started; `head` cut off the rest. Second, delete the
  goroutine that closes `results`. The receiving loop waits forever, and
  once the scanning goroutines have finished the runtime notices:

  #output("ch00/s14-deadlock.txt")

  `goroutine 1 [chan receive]` is `main`, stuck receiving in `scanAll` at
  `scan.go:65`, the `range` loop. Third, remove the `slots` limit and scan
  300 files with a low open-file limit. `ulimit -SHn 64` lowers both the
  soft and the hard limit to 64 for this shell only (lowering just the
  soft limit would not show anything, because Go raises it again). Open a
  new terminal afterwards to get your normal limits back:

  #output("ch00/s14-fds.txt")

  Run it a few times and you may instead see the program die with
  `runtime: kqueue failed with 1` and
  `fatal error: runtime: netpollinit failed` (on Linux the first line
  says `epollcreate failed`), followed by hundreds of lines
  of goroutine stacks. That is the same problem: the Go runtime itself
  needed a file descriptor at a moment when the scans held them all.

  With the limit back in place, the same 300 files under the same
  `ulimit` scan cleanly, four at a time:

  #output("ch00/s14-fds-ok.txt")

  #troubleshoot(
    ([`WARNING: DATA RACE` with two stacks], [Two goroutines used one variable without coordination], [Give each goroutine its own data, or use a channel or `sync.Mutex`; see "Data races"]),
    ([`fatal error: all goroutines are asleep - deadlock!`], [A loop ranges over a channel that is never closed, or a send has no receiver], [Close the channel after `wg.Wait()`; see "Channels"]),
    ([`too many open files`, or `fatal error: runtime: netpollinit failed`], [More files are open at once than the process may have], [Bound concurrency with a semaphore channel like `slots`]),
    ([Output order changes between runs], [Results are printed in the order goroutines finish], [Store results by index, as `ordered` does]),
  )
]

== Where this goes next <sec-zero-next>

You have written a real tool: about 500 lines of Go in four packages, with
tests, a linter, documented exit codes and bounded concurrency. Every idea
in it comes back later in the book, in more depth and at larger scale.
This table says where:

#table(
  columns: (1.2fr, 1fr, 1.6fr),
  table.header([Idea from this chapter], [Chapter], [What that chapter adds]),
  [Modules, `go.mod`, the toolchain, linters], [1: The Platform Engineer's Go], [Toolchain versions, workspaces, project layout, a full linter setup],
  [Small interfaces, exported names, generics], [2: Designing Go APIs That Last], [Functional options, package boundaries, generic methods, API stability],
  [Errors as values, wrapping, exit codes], [3: Errors, Exit Codes, and Failure as a Feature], [Typed errors, `errors.Join`, exit-code contracts, messages for users and operators],
  [Goroutines, channels, `WaitGroup`, bounded work], [4: Concurrency Patterns for Production Tooling], [The scheduler, contexts and cancellation, worker pools, retries, graceful shutdown],
  [`io.Reader`, streaming, files, standard input], [5: Talking to the Operating System], [Buffers and throughput, atomic writes, processes and signals, OOM kills in containers],
  [Table-driven tests, coverage, `-race`], [6: Testing Tools That Touch the Real World], [Golden files, testing CLIs end to end, fuzzing, benchmarks],
  [Structs, methods, interfaces, all of the above], [20: Building Operators with controller-runtime], [A Kubernetes operator built step by step, in the same style as this chapter],
)

Two habits matter more than any single feature. First, when something
fails, read the whole message: the file and line, the `have` and `want`,
the first frame of the stack that is your code. You saw dozens of real
errors in this chapter, and each one said what was wrong. Second, keep the
loop short. Change one thing, run the tests, look at the output. The
chapters that follow are bigger, but they are built the same way: one
working step at a time.

#takeaways(
  [A Go program is a module of packages. `go mod init` starts one; `go run`, `go build`, `go vet` and `go test ./...` are the daily commands.],
  [Every value has a type, every variable starts at its zero value, and Go never converts types for you. Unused variables and imports do not compile.],
  [Functions return errors as values. Check `err != nil` where it happens, wrap with `fmt.Errorf("...: %w", err)`, and test with `errors.Is` and `errors.As`.],
  [Stream big inputs: `bufio.Scanner` over an `io.Reader` uses memory for one line; `io.ReadAll` uses memory for the whole input. Always check `scanner.Err()`.],
  [Slices grow with `append` (keep the result); maps need `make` before writing and have no order.],
  [A method that changes its receiver needs a pointer receiver; a value receiver works on a copy.],
  [An exported name starts with a capital letter. An interface is satisfied by having its methods, so keep interfaces small and define them where they are used.],
  [Accept `io.Reader` and `io.Writer` instead of files and the terminal, and your code works with pipes, buffers and tests unchanged.],
  [A function that starts goroutines waits for them; the sender closes a channel; bound concurrency by what the resource allows; run tests with `-race`.],
)

#exercise-set(0,
  (
    tier: "warm-up",
    title: [Level aliases],
    body: [
      Some programs write `WARNING` instead of `WARN` and `ERR` instead of
      `ERROR`. Change `logline.ParseLevel` so it accepts both aliases, in any
      letter case, as well as the existing names. `Parse` uses
      `ParseLevel`, so log lines with the aliases parse too, and so does
      `-level warning`. Names that are close but wrong, such as
      `WARNINGS`, must still be rejected.
    ],
    hint: [A map from upper-case alias to `Level`, checked before the loop,
      keeps the aliases in one place. `strings.ToUpper` normalizes the case.],
    tests: "workbook/ch00/exercises/ex1",
  ),
  (
    tier: "warm-up",
    title: [Percentages per level],
    body: [
      Add a method `Percent(l Level) float64` to `logline.Stats` that
      returns the share of entries at level `l` as a percentage, and 0 for
      a `Stats` with no entries. Then use it in `Print` for the error
      share.
    ],
    hint: [The package already has a helper that guards against dividing
      by zero.],
    tests: "workbook/ch00/exercises/ex2",
  ),
  (
    tier: "warm-up",
    title: [Read it before you run it],
    body: [
      For each program below, say whether it compiles. If it does not,
      predict the compiler's message. If it does, say what it prints or how
      it fails. Then run each one in a scratch module and compare.

      #block(breakable: false)[#grid(columns: (1fr, 1fr), column-gutter: 10pt,
        code(file: "a/main.go")[```go
        func main() {
        	count := 0
        	count := count + 1
        	fmt.Println(count)
        }
        ```],
        code(file: "b/main.go")[```go
        func main() {
        	var port int = "8080"
        	fmt.Println(port)
        }
        ```],
        code(file: "c/main.go")[```go
        func main() {
        	names := []string{"api", "db"}
        	for i := range names {
        		fmt.Println(names[i+1])
        	}
        }
        ```],
        code(file: "d/main.go")[```go
        func main() {
        	counts := map[string]int{"INFO": 3}
        	counts["WARN"]++
        	fmt.Println(counts["WARN"],
        		counts["ERROR"], len(counts))
        }
        ```],
      )]

      Each file also starts with `package main` and `import "fmt"`.
    ],
    hint: [Two do not compile, one panics, and one prints something that
      surprises people coming from Python.],
  ),
  (
    tier: "core",
    title: [Filter by service],
    body: [
      Add a matcher type `match.Service` that selects entries from one
      service, comparing names without regard to case, and teach
      `Describe` to print it as `service=api`. Then add a flag
      `-service NAME` that adds the matcher to the query, after the level
      and before any text filters.
    ],
    hint: [`Contains` is the closest model. `strings.EqualFold` compares
      without case. `buildMatcher` needs one more parameter.],
    tests: "workbook/ch00/exercises/ex4",
  ),
  (
    tier: "core",
    title: [Invert the query],
    body: [
      `grep -v` prints the lines that do _not_ match. Add a function
      `match.Not(m Matcher) Matcher` that returns a matcher selecting what
      `m` rejects, make `Describe` print it as `not (...)`, and add a flag
      `-v` that inverts the whole query.
    ],
    hint: [This is the decorator pattern from Step 11: an unexported struct
      holding the wrapped matcher, with its own `Match` method. Wrap the
      result of `buildMatcher`, not each part.],
    tests: "workbook/ch00/exercises/ex5",
  ),
  (
    tier: "core",
    title: [Read compressed logs],
    body: [
      Rotated logs are usually compressed: `app.log.1.gz`. Make `logq` read
      any file whose name ends in `.gz` through `compress/gzip`, so
      `logq -level error app.log.1.gz` works. A file that ends in `.gz` but
      is not gzip data must produce an error that names the file, and exit
      status 2.
    ],
    hint: [`gzip.NewReader` takes an `io.Reader` and is one. Only
      `scanFile` needs to change; `scan` already accepts any reader.],
    tests: "workbook/ch00/exercises/ex6",
  ),
  (
    tier: "core",
    title: [Explain the race],
    body: [
      Look again at the data race report in the Step 14 checkpoint and the
      version of `scanAll` that caused it, in which each goroutine runs
      `results = append(results, r)` on one shared slice. Answer in a few
      sentences each: (a) Which variable is raced on, and what are the two
      conflicting accesses? (b) Why did the normal build print plausible
      counts anyway? (c) Name two different ways to fix it, and say which
      one `logq` uses. (d) Why does `ordered[r.index] = r` in the real
      `scanAll` not race, although it also writes to a shared slice?
    ],
    hint: [`append` both reads and writes the slice header. Think about
      which goroutine runs each line.],
  ),
  (
    tier: "stretch",
    title: [Read JSON logs too],
    body: [
      Many services log JSON. Make `logline.Parse` accept a line that starts
      with `{` as a JSON object with the fields `time`, `level`, `service`
      and `message`, reporting a malformed object as a `*ParseError` with
      `Field` set to `"json"` and a bad time or level with those fields, as
      for text lines. Also give `Level` an `UnmarshalText` method, so a
      `Level` decodes from JSON. As a result, `logq` can read its own
      `-json` output: `logq -json app.log | logq -count`.
    ],
    hint: [Decode into a struct whose fields are all strings first, then
      reuse `time.Parse` and `ParseLevel`, so each problem maps to the right
      field.],
    tests: "workbook/ch00/exercises/ex8",
  ),
  (
    tier: "stretch",
    title: [Busiest minutes],
    body: [
      During an incident you want to know _when_ things went wrong. Add a
      flag `-by` that chooses what `-top` ranks: `service` (the default) or
      `minute`. Count entries per minute in `Stats` as a
      `map[time.Time]int`, keyed by `e.Time.Truncate(time.Minute)`, and
      print minutes as `15:04`. Because `time.Time` does not satisfy
      `cmp.Ordered`, add `rank.TopFunc[K comparable]`, which takes a
      comparison function for keys, and rewrite `Top` to call it. Reject
      any other `-by` value with exit status 2.
    ],
    hint: [`time.Time.Compare` is a method expression with exactly the type
      `func(a, b time.Time) int`. `cmp.Compare[K]` is the same for ordered
      keys.],
    tests: "workbook/ch00/exercises/ex9",
  ),
)
