# Code editor

What is still open about the code editor of the web client: the parser that keeps the structure of
the code while the user types, the language server that gives its meaning, which drags of code
Julia allows, and how the host captures the values shown in the code. Nothing here is built. The
[vision](../vision.md) gives the goals of the editor, which follow Hazel, and the split of its work
between a parser in the editor, the Julia language server in the host and the client API.
[Runtime and clients](runtime-and-clients.md) follows a save to the redraw, and [tabs](tabs.md)
covers analysis files and the window that shows a local value.

## Structure while typing

Hazel's parser gives a complete syntax tree for any text. Where something is missing, the parser
puts a *hole*, a placeholder that the rest of the editor treats as an expression, so typing never
leaves the editor without structure. The editor needs such a parser for Julia, and it must answer
each keystroke without a trip to another process. The language server reads code with Julia's own
parser, as Julia does when it loads a file.

The candidates have these properties:

- **tylr** is the parser of Hazel. For its latest form, the paper "Syntactic Completions with
  Material Obligations" (OOPSLA 2025) proves that any sequence of tokens completes into a
  well-formed term. tylr is a generator: it takes a grammar of precedence levels and extends
  operator-precedence parsing. The paper states its limits: little optimization, responsive below
  about 100 lines, and no incremental parsing. It is written in Reason and OCaml and compiled for
  the web browser.
- **JuliaSyntax.jl** is Julia's own parser. With `ignore_errors=true` it returns a tree with
  `error` nodes. A stray `)` becomes one error node and the later statements stay intact; an
  unclosed `(` takes in the next line; a missing `end` takes in the rest of the file. It has no
  incremental parsing, and the compilers from Julia to WebAssembly that could run it in a web
  browser are experimental.
- **tree-sitter-julia** runs in a web browser as WebAssembly and parses incrementally. It has no
  active maintainer, and it parses some valid Julia code wrongly.
- **lezer-julia** is the grammar for CodeMirror 6 that Pluto uses. It always gives a tree and
  parses incrementally, and it also parses some valid Julia code wrongly.

How well the method of tylr fits Julia is unknown. Julia has newlines that end statements, spaces
that matter inside brackets (`[a -b]`), juxtaposition (`2x`), macros and nested string
interpolation, and none of these is plain operator precedence.

## Meaning: the Julia language server

Features for writing code go through LSP, and the same server answers the code editor and VS Code.
A hard fork of JETLS is one way to build it. The editor needs three things from the server that
the Julia language servers of today lack, and all three are proposals:

- **Types from the calls that ran.** The workspace knows the argument types of every call that it
  ran. The server infers each method with those types, so a method declared as `process(item)`
  shows the types that it really works with.
- **Proofs for drags:** the scope of each name and the side effects of each expression.
- **The places that call a method**, from the calls that ran and from inference.

The existing servers and the protocol have these properties:

- **JETLS** calls itself experimental. Its full analysis runs when a file is opened or saved, and
  infers each method from its declared signature; while the user types, it only parses and lowers
  the code. It documents no way to give it the types seen at run time. It offers rename and find
  references, matched by name and module, and it has no "extract" action.
- **LanguageServer.jl** analyses code statically, with StaticLint on CSTParser trees. Its code
  actions are small rewrites, and it has no "extract" action either.
- **LSP 3.17** has `textDocument/inlayHint` for text shown inside the code, and
  `textDocument/publishDiagnostics`, which a server sends at any time. Its
  `textDocument/inlineValue` is designed for a debugger stopped at a line. A server can add
  requests of its own, as rust-analyzer does.

## Dragging code

In [the Hazel clip](https://declarative-dragging.github.io/clips/hazel-refactoring.mp4) of the
paper [Declarative Dragging](https://declarative-dragging.github.io/D2.pdf), the user grabs an
expression without selecting text and moves it across brackets and scopes. While the user drags,
the editor shows how the program would change at each place where the expression could land, and
restructures the code around it as needed. One gesture serves every operation: its meaning follows
from what is grabbed, where it goes, and the structure around it. The clip shows five operations:

| Operation | The drag | What the editor does |
| --- | --- | --- |
| Extract | An arithmetic expression | Gives the expression a name of its own |
| Hoist with dependencies | An expression, out of its scope | Moves the expression together with the local variables that it uses |
| Swap params | A parameter of a function, across another | Exchanges the parameters, and the arguments wherever the function is called |
| Flip branches | A branch of an `if`, across the other | Exchanges the branches and negates the condition |
| Hoist, or Join into tuple | A `let` binding, out of the expression around it | Moves the binding outward, or joins it with another binding |

Julia changes two of them. Hazel's language has no side effects, so an expression gives the same
value wherever it runs and however often, while in Julia an expression moved out of a loop runs
once. Also, the method that a Julia call reaches depends on the types at run time, so Swap params
finds the places that call the method from the calls that ran and from inference, and lists the
uncertain ones for the user to confirm.

Macros raise a third problem: a macro can give the same text another meaning. A proposal: the
editor leaves the arguments of a macro alone unless the macro states how it uses them, as
DataBrowser's own macros, such as `@plot`, can.

The dragging itself can use Dragology, the dragging library of the paper: TypeScript, drawing with
SVG, for React, MIT license, without documentation so far. Hazel's own drag refactorings (branch
`refactorings`, file `RefactorDrag.re`) implement the ideas of the paper without the library. The
layout of the code is the editor's own, so Dragology can serve it. Existing editors offer no base:
CodeMirror 6 and Monaco have no dragging of structure, and the editors that have it (Droplet,
codemirror-blocks, Strype, MakeCode) show code as blocks or frames in place of plain text.

## Values in the code

From a value, such as the figure of a window, the user opens the code of the computation that
produced it, and the editor shows beside each local variable the value that it had in that
computation. The host captures these values, and three facts bound how:

- The values inside a completed computation exist only if the host kept them while it ran. A
  repeatable computation runs again to give them, while an acquisition or an instrument command is
  never repeated.
- Capturing the values of one call is cheap when only that one function runs in an interpreter and
  everything that it calls runs compiled. With JuliaInterpreter on `sum(abs2, sort(x))`, this takes
  about the time of a normal run, a few milliseconds, while interpreting everything takes about
  65,000 times more.
- Hazel never hangs because it evaluates in a worker of the web browser, which it stops and
  replaces when a program runs longer than 20 s. The Julia host has the same role, and DBCore stops
  and replaces it.

The values reach the editor through the client API, as data. The protocol serves them to other
editors too; in VS Code the language server can show them as inlay hints.

## Open questions

- Is LSP the right carrier for everything that the editor asks the language server? The programs
  that each drop leads to have no request in LSP today.
- Is the language server a hard fork of JETLS, or new work?
- Is the parser the method of tylr applied to Julia, or a tolerant parser on an existing Julia
  grammar? Either one must stay responsive on files of thousands of lines.
- What does the editor show for a line that ran many times in one computation, such as a line
  inside a loop?
- Does the editor evaluate text before the save? Other programs learn about a change when the file
  is saved, and the answer follows from what gives the best experience.
- How does a macro state how it uses its arguments?
