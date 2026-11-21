# Code editor

The [vision](../vision.md) sets the goals for the web client's structural code editor (modeled on
Hazel) and splits its work between an in-browser parser, a Julia language server in the host, and
the client API; [Runtime and clients](runtime-and-clients.md) follows a file save to redrawing, and
[tabs](tabs.md) covers analysis files and debug windows. Nothing here is built yet: the parser,
language-server extensions, legal code drags, and runtime value capture remain open.

## Structure while typing

Hazel's parser produces a complete syntax tree for any text by inserting a *hole* — a placeholder
treated as an expression by the rest of the editor — wherever code is incomplete, so typing never
leaves the editor without syntax structure. Our editor needs a similar parser for Julia that reacts
to every keystroke without a round-trip to another process, while the language server still parses
saved files with Julia's own parser.

Four parser candidates have these properties:

- **tylr** is Hazel's parser. The paper "Syntactic Completions with Material Obligations" (OOPSLA
  2025) proves its latest algorithm turns any token sequence into a well-formed term by extending
  operator-precedence parsing over a precedence grammar. Its documented limits are minimal
  optimization (staying responsive below roughly 100 lines), no incremental parsing, and an
  OCaml/Reason implementation compiled to JavaScript for the browser.
- **JuliaSyntax.jl** is Julia's built-in parser. With `ignore_errors=true`, it returns a tree
  containing `error` nodes: a stray `)` becomes one error node leaving later statements intact,
  whereas an unclosed `(` swallows the next line and a missing `end` swallows the rest of the file.
  It lacks incremental parsing, and Julia-to-WebAssembly compilers able to run it in the browser
  remain experimental.
- **tree-sitter-julia** runs in a browser as WebAssembly and parses incrementally, yet lacks an
  active maintainer and misparses some valid Julia syntax.
- **lezer-julia** is the CodeMirror 6 grammar used by Pluto; it always returns a tree and parses
  incrementally, yet also misparses some valid Julia syntax.

How well tylr's approach fits Julia is untested, because Julia relies on newlines ending
statements, significant whitespace inside brackets (`[a -b]`), juxtaposition (`2x`), macros, and
nested string interpolation — none of which reduces cleanly to operator precedence.

## Meaning: the Julia language server

Writing and refactoring code goes through LSP, so one server can serve both our code editor and VS
Code; hard-forking JETLS is one option. The editor needs three capabilities missing from today's
Julia language servers:

- **Types from executed calls.** Because the workspace records the argument types of every call that
  ran, the server can infer each method with those observed types so a generic signature like
  `process(item)` displays the actual types it runs on.
- **Proofs for drags:** lexical scope of every name and side effects of every expression.
- **Actual call sites** for each method, combined from observed runs and type inference.

Existing servers and LSP offer this baseline:

- **JETLS** describes itself as experimental. Its full analysis runs on open or save and infers each
  method from its declared signature, while during typing it only parses and lowers code; it has no
  documented hook for runtime argument types, offers only name-and-module rename and find-references,
  and has no "extract" refactoring.
- **LanguageServer.jl** analyzes code statically via StaticLint over CSTParser trees, offering small
  code actions without an "extract" refactoring.
- **LSP 3.17** provides `textDocument/inlayHint` for inline annotations and
  `textDocument/publishDiagnostics` at any time (while `textDocument/inlineValue` assumes a paused
  debugger), and servers can add custom requests as `rust-analyzer` does.

## Dragging code

In [the Hazel clip](https://declarative-dragging.github.io/clips/hazel-refactoring.mp4) from
[Declarative Dragging](https://declarative-dragging.github.io/D2.pdf), a user grabs an expression
without selecting text and drags it across brackets and scopes. During the drag, the editor previews
valid drop targets and restructures surrounding code automatically, unifying five refactorings under
one gesture:

| Operation | Dragged syntax | Editor action |
| --- | --- | --- |
| Extract | an arithmetic expression | binds the expression to a new name |
| Hoist with dependencies | an expression out of its scope | moves the expression together with the local variables it uses |
| Swap params | a function parameter past another | swaps the parameters and updates arguments at every call site |
| Flip branches | one branch of an `if` past the other | swaps the branches and negates the condition |
| Hoist, or Join into tuple | a `let` binding out of its enclosing expression | moves the binding outward or merges it with another binding |

Julia complicates two of those operations. First, unlike Hazel's pure language, Julia allows side
effects, so hoisting an expression out of a loop makes it run once instead of every iteration.
Second, dispatch depends on runtime types, so Swap params must combine observed calls with inference
and ask the user to confirm uncertain call sites. Macros add a third complication by rewriting their
arguments arbitrarily; one proposal leaves macro arguments untouched unless the macro declares how
it uses them, as DataBrowser's own macros (such as `@plot`) can.

For the UI gesture itself, the paper's Dragology library (TypeScript, SVG, React, MIT-licensed,
undocumented) or Hazel's own `refactorings` branch (`RefactorDrag.re`) provides a starting point
since the editor owns its text layout. Mainstream editors like CodeMirror 6 and Monaco lack
structural dragging, whereas structural editors like Droplet, `codemirror-blocks`, Strype, and
MakeCode replace plain text with visual blocks or frames.

## Values in the code

Opening the code behind a displayed figure or value shows, beside each local variable, the value
it held during the computation that produced it. Three constraints govern how the Julia host
captures those values:

- Values inside a completed computation exist only if the host recorded them while running; a
  repeatable computation can rerun to produce them, whereas an acquisition or instrument command
  never repeats.
- Capturing locals inside a single call stays cheap when only that top function runs interpreted and
  everything it calls runs compiled: with `JuliaInterpreter` on `sum(abs2, sort(x))`, that takes a
  few milliseconds (comparable to a compiled run), whereas interpreting callees takes roughly 65,000
  times longer.
- Hazel never hangs because evaluation runs in a web worker killed and restarted after 20 s; the
  Julia host plays that same role under DBCore.

Captured values reach the editor through the client API as data, allowing other editors such as VS
Code to display them as inlay hints via the language server.

## Open questions

- Does LSP fit every query the editor needs from the language server, given that LSP currently lacks
  requests for candidate refactorings along a drag path?
- Should the Julia language server start as a hard fork of JETLS or from scratch?
- Should the tolerant in-browser parser adapt tylr's method to Julia or wrap an existing Julia
  grammar, staying responsive on files of thousands of lines?
- How should the editor display local values for lines executed repeatedly inside a loop?
- Should the editor evaluate unsaved text before a file is saved, or only on save?
- How should macros declare how they inspect and transform their arguments?
