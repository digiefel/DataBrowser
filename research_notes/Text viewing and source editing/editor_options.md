# Text viewing and source editing components

Research date: 12 October 2026. This is a read-only survey. No editor dependency was installed, compiled, or called, and no DataBrowser private API was called. References to implementation files below are inspection evidence, not proposed extension interfaces.

## What rendering stack and public boundary must a text component fit?

### Takeaway

The current desktop is Dear ImGui through CImGui, GLFW, and OpenGL3. A text component that draws inside that stack has substantially less integration work than a browser or native operating-system editor control. A documented way to open and draw a generic visualizer remains a separate DataBrowser requirement; an available ImGui widget does not establish that public API.

### Cited Findings

- The root environment resolves **CImGui 8.0.0**, **CImGuiPack_jll 0.12.2+0**, **GLFW.jl 3.4.6**, and **GLFW_jll 3.4.1+1**. The root and GUI/Plots packages allow CImGui 8.0 and GLFW 3.4.4, rather than pinning those exact patches. — [Manifest.toml:53](/Users/davide/code/Julia/DataBrowser-dev/Manifest.toml:53), [Manifest.toml:69](/Users/davide/code/Julia/DataBrowser-dev/Manifest.toml:69), [Manifest.toml:340](/Users/davide/code/Julia/DataBrowser-dev/Manifest.toml:340), [GUI Project.toml:19](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserGUI/Project.toml:19), [Plots Project.toml:23](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserPlots/Project.toml:23).
- The compatible installed CImGui 8.0.0 wrapper identifies its upstream header as **v1.92.8-docking**. Its `InputTextMultiline` wrapper already accepts buffer, byte capacity, size, flags, callback, and user data. — [installed CImGui wrapper:1795](/Users/davide/.julia/packages/CImGui/Z6T2G/src/wrapper.jl:1795), [installed CImGui Project.toml:4](/Users/davide/.julia/packages/CImGui/Z6T2G/Project.toml:4). The current public CImGui stable documentation is newer, at 1.92.9-b, so it must not be mistaken for this workspace's resolved ABI. — [CImGui docs](https://juliaimgui.github.io/ImGuiDocs.jl/cimgui/stable/).
- The browser configures GLFW/OpenGL3, docking, multiple viewports, and keyboard navigation. — [Layout.jl:311](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserGUI/src/Gui/Layout.jl:311). CImGui documents GLFW/OpenGL3 as its supported backend, and recommends running the render task on thread 1 for safety. — [CImGui backends](https://juliaimgui.github.io/ImGuiDocs.jl/cimgui/stable/backends/).
- The vision requires visualizers to consume data through package access functions, rather than reading source/cache files or GUI state directly. Generic visualization is a capability over arbitrary data. — [vision.md:79](/Users/davide/code/Julia/DataBrowser-dev/docs/vision.md:79), [vision.md:294](/Users/davide/code/Julia/DataBrowser-dev/docs/vision.md:294).
- The roadmap explicitly lists public GUI extension/window surfaces as unfinished work, including built-in visualizers using the same surfaces as extensions. — [roadmap.md:488](/Users/davide/code/Julia/DataBrowser-dev/docs/roadmap.md:488). The current extension source has `init!`, `draw!`, `menu!`, persistence, item-context-menu, and docking hooks, but their existence must not be presented as a fully documented public contract. — [Extensions.jl:1](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserGUI/src/Browser/Extensions.jl:1).
- Registered plot callbacks currently receive loaded, processed `AbstractDataItem`s. Their `embed(figure, id)` method draws the figure in the current browser window. This does not itself establish source-stage viewing or a general document editor. — [plots.jl:66](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserPlots/src/plots.jl:66), [plots.jl:76](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserPlots/src/plots.jl:76).

### Inferences

- The reader and source editor should be separate consumers of one document representation. Read-only data should not acquire saving, undo history, file watching, or language-server state merely because it can be displayed as text.
- A future text visualizer can accept a text payload or a public text-access operation for a source-stage item. It should receive the result through the public pipeline, rather than reopening an item's path on its own. Whether source-stage results can be requested without loading later stages is a pipeline decision.
- An editor needs a public project-source document operation independent of the data-item loader. Its save operation changes project files; its buffer need not become a processed data item.

### Gaps

- No prototype was run, so upstream version compatibility is source-level evidence, not proof of compiled ABI or runtime integration.
- No maintained Julia binding for ImGuiColorTextEdit or Zep was established in this survey. That is not proof that none exists. A binding/artifact review is required before selecting either.
- The public visualizer/session/selection contract and project-code reload semantics must be supplied by DataBrowser before an external extension can deliver these modes without private access.

## Which editor and viewer components are practical?

### Takeaway

A clipped read-only ImGui line viewer is the lowest-cost general inspection path. Native `InputTextMultiline` can provide a deliberately limited single-buffer editing experiment, but its undo ownership makes it a weak foundation for project-file tabs. The goossens rewrite of ImGuiColorTextEdit is the strongest native-stack candidate to investigate next. CodeMirror and Monaco bring richer editing with a much larger embedding change.

### Cited Findings

The integration estimates in this matrix are judgments from the cited interfaces, not measured implementation times.

| Choice | Confirmed strengths | Cost or unresolved limitation in this app | Position |
|---|---|---|---|
| ImGui text rows + `ImGuiListClipper` | Draws visible rows; supports random-access, equal-height lists. | Application supplies line offsets, search, line numbers, copy/selection. Wrapped variable-height lines need another layout strategy. | First generic viewer. [ImGui header](https://raw.githubusercontent.com/ocornut/imgui/v1.92.8-docking/imgui.h) |
| Native `InputTextMultiline` | Existing Julia wrapper; read-only flag, selection/clipboard, undo/redo, tab input, word wrap. | Full text input lifecycle; one current input state; no complete source-editor UI. Very long lines are a documented pathological case. | Small single-buffer experiment. [ImGui widgets](https://raw.githubusercontent.com/ocornut/imgui/v1.92.8-docking/imgui_widgets.cpp) |
| Original ImGuiColorTextEdit | UTF-8 API, undo, coloring, error markers; MIT. | Original README acknowledges slow regex coloring outside C/C++; current compatibility and maintenance need verification. | Do not prefer original over evaluated maintained rewrite. [Original](https://github.com/BalazsJako/ImGuiColorTextEdit) |
| santaclose fork | Multiple cursors, indentation/comment shortcuts; expanded languages. | Fork README lists Boost regex work and still acknowledges slow regex coloring in most languages. | Compare only if rewrite has a concrete regression. [Fork](https://github.com/santaclose/ImGuiColorTextEdit) |
| goossens rewrite | C++17; macOS/Linux/Windows; explicitly supports ImGui 1.92.8/1.92.9; persistent editor object; find/replace, undo, clipboard, wrap/folding, markers/squiggles. | Needs C ABI + artifact matched to ImGui; no built-in Julia definition in inspected header; codepoint width follows ImGui. | Best native-stack follow-up. [Rewrite](https://github.com/goossens/ImGuiColorTextEdit), [header](https://raw.githubusercontent.com/goossens/ImGuiColorTextEdit/master/TextEditor.h) |
| Zep | Rendering-independent C++14 core; ImGui/Qt renderers; standard/Vim modes, tabs/splits, markers, search, tests. | README still calls UTF-8 incomplete and some modes work in progress; Julia language support and current ImGui ABI unverified. | Interesting if modal editing is a requirement. [Zep](https://raw.githubusercontent.com/Rezonality/zep/master/README.md) |
| CodeMirror 6 | Modular web editor; line numbers, search/replace, undo, multiple selections, accessibility, bidi, large-document virtualization. Julia legacy stream mode exists. | Requires browser/DOM and Julia↔JavaScript document bridge. Julia legacy mode is syntax coloring, not a Julia language service. | Preferred web candidate if a browser surface is adopted. [Features](https://codemirror.net/), [guide](https://codemirror.net/docs/guide/), [Julia mode](https://raw.githubusercontent.com/codemirror/legacy-modes/main/mode/julia.js) |
| Monaco | VS Code editor component; models, markers, completion providers, find/folding/read-only/accessibility options. MIT. | Browser, bundled assets, workers, bridge; VS Code extensions do not simply run inside Monaco. Julia integration remains to select. | Choose for a deliberate richer web IDE direction. [Monaco](https://github.com/microsoft/monaco-editor), [API](https://microsoft.github.io/monaco-editor/typedoc/interfaces/editor_editor_api.editor.IStandaloneEditorConstructionOptions.html) |
| Scintilla + Lexilla | Established native editor; source styling, selection, undo, search, markers, completion, wrapping, platform IME support; Julia lexer exists. | Native Win32/GTK/Cocoa/Qt control, rather than ImGui draw commands; requires platform-specific embedding/focus integration. | Strong editor, poor first fit for the present shell. [Scintilla](https://www.scintilla.org/ScintillaDoc.html), [Julia lexer](https://raw.githubusercontent.com/ScintillaOrg/lexilla/master/lexers/LexJulia.cxx) |
| External VS Code/editor handoff | File/line opening is already available; e.g. `code --goto file:line:column`. | Outside-app focus and file watching/reload remain; does not satisfy final in-app writing goal. | Useful now for the no-restart workflow. [VS Code CLI](https://code.visualstudio.com/docs/configure/command-line) |

#### Native multiline: important limits

- Native multiline uses UTF-8 edit state in 1.92.8. Read-only activation avoids the editable `TextA` copy, but still copies the initial text for revert bookkeeping. Layout rebuilds a line index from the supplied text. It is therefore incorrect to describe it as necessarily decoding the whole document to UTF-16, or as doing only visible-row work. Undo state is recycled only when the previous input state belongs to the same widget; activating a different text input initializes another state. The source also warns that a pathological multiline line can exceed its rendering guard. — [v1.92.8 widgets, activation/layout/render sections](https://raw.githubusercontent.com/ocornut/imgui/v1.92.8-docking/imgui_widgets.cpp).
- Dear ImGui's public list clipper is specifically for equal-height random-access items. It reduces submission work for long lists. Plain `TextUnformatted` rows do not provide character-range selection and copying by themselves. — [v1.92.8 header, list clipper and text APIs](https://raw.githubusercontent.com/ocornut/imgui/v1.92.8-docking/imgui.h).
- Dear ImGui is MIT licensed. — [license](https://raw.githubusercontent.com/ocornut/imgui/v1.92.8-docking/LICENSE.txt).

#### Unicode, keyboard and input methods

- The installed arm64 macOS binding defines `ImWchar = ImWchar16`. — [binding:575](/Users/davide/.julia/packages/CImGui/Z6T2G/lib/aarch64-apple-darwin20.jl:575). In pinned upstream code, the Unicode maximum depends on `IMGUI_USE_WCHAR32`; input-event processing replaces characters beyond that maximum, and the UTF-8 decoder also checks it. This is stronger evidence of input/display limitations than a missing font alone. It does **not** prove that an untouched UTF-8 source buffer is rewritten on save. — [v1.92.8 core](https://raw.githubusercontent.com/ocornut/imgui/v1.92.8-docking/imgui.cpp).
- The goossens editor explicitly stores 16- or 32-bit codepoints according to ImGui configuration, and documents the BMP restriction with the default 16-bit configuration. It uses ImGui font support. — [rewrite Unicode section](https://raw.githubusercontent.com/goossens/ImGuiColorTextEdit/master/README.md).
- The GLFW backend forwards character events and clipboard functions. It does not install a `Platform_SetImeDataFn` in the inspected pinned source; ImGui's core supplies a Windows IME positioning implementation and a no-op elsewhere. This does not establish absence of committed CJK input via GLFW, but parity of candidate positioning/composition is unverified. — [GLFW backend](https://raw.githubusercontent.com/ocornut/imgui/v1.92.8-docking/backends/imgui_impl_glfw.cpp), [core IME implementation](https://raw.githubusercontent.com/ocornut/imgui/v1.92.8-docking/imgui.cpp).
- UTF-8 strings and a font with the required glyphs are both necessary; from 1.92, updated backends can load glyphs without manually declared ranges. — [ImGui FAQ](https://raw.githubusercontent.com/ocornut/imgui/master/docs/FAQ.md).
- CodeMirror positions count UTF-16 code units; this differs from Julia byte/string indexes. Scintilla positions usually count bytes, including multibyte encodings. — [CodeMirror guide](https://codemirror.net/docs/guide/), [Scintilla text positions](https://www.scintilla.org/ScintillaDoc.html).

#### Binding and distribution

- A mutable native ImGui input buffer must have valid capacity and NUL termination. Its resize callback changes the buffer pointer/capacity. The official C++ standard-string helper demonstrates that contract. — [imgui_stdlib.cpp](https://raw.githubusercontent.com/ocornut/imgui/master/misc/cpp/imgui_stdlib.cpp).
- Julia documents caller-owned `Vector{UInt8}` buffers, `@cfunction`, rooting callbacks, and `GC.@preserve` for memory used through pointers. — [Julia C interop manual](https://raw.githubusercontent.com/JuliaLang/julia/master/doc/src/manual/calling-c-and-fortran-code.md).
- The goossens widget is supplied as C++ source, creates one persistent object per editor, and draws each frame. Its API exposes a context setter for separate DLL builds; this is not a C ABI. The public language definitions in the inspected header do not include Julia. — [rewrite integration](https://github.com/goossens/ImGuiColorTextEdit), [header](https://raw.githubusercontent.com/goossens/ImGuiColorTextEdit/master/TextEditor.h). Its MIT license is confirmed. — [license](https://raw.githubusercontent.com/goossens/ImGuiColorTextEdit/master/LICENSE).
- Dear ImGui explicitly does not guarantee backward/forward ABI compatibility for shared-library users. — [upstream header](https://raw.githubusercontent.com/ocornut/imgui/master/imgui.h). CImGui's contribution guide explains coordinated JLL/binding updates. — [CImGui contribution guide](https://juliaimgui.github.io/ImGuiDocs.jl/cimgui/stable/contributing/).
- A lightweight webview library is still a native browser surface: `webview` uses WebKitGTK on Linux, Cocoa/WebKit on macOS, and WebView2 on Windows, with two-way JavaScript bindings. Linux distribution requires GTK/WebKitGTK; older Windows installations require the WebView2 runtime. — [webview platform/distribution documentation](https://github.com/webview/webview).
- Monaco documents models and disposal, browser workers, and HTTP/HTTPS rather than `file://` for workers. Its versioned public API is `monaco.d.ts`; VS Code extension compatibility must not be assumed. — [Monaco README](https://raw.githubusercontent.com/microsoft/monaco-editor/main/README.md).
- Scintilla has a permissive custom license, not an MIT label. Its current official front page lists release 5.6.7, dated September 2026, while its download page can lag. — [license](https://www.scintilla.org/License.txt), [current front page](https://www.scintilla.org/).

### Inferences

- Native multiline is useful for proving file opening/saving and seeing whether writing short recipes in the app feels useful. It should be described as a prototype with limited undo behavior. Adding a separate search input or switching file tabs can expose that limit immediately; reimplementing per-document undo around private ImGui state would violate the public-API constraint and defeat the small experiment.
- A goossens binding should expose opaque handles and coarse operations: create/destroy, load text, render, dirty/version query, retrieve text, cursor/selection, and markers. Do not expose STL containers or invoke Julia for every glyph/token. Either compile it with the matching ImGui artifact or link to the same implementation with the same build configuration and explicit context handling. Shipping a second independent ImGui core is not a safe default.
- A full-Unicode artifact change affects the native ABI, including ImGui and widget types. It is packaging work, not a Julia-only type alias edit.
- Choosing CodeMirror or Monaco means choosing a browser host as well as an editor. A sibling webview window is simpler than compositing it into a draggable/dockable ImGui viewport, but changes the interaction model. An offscreen Chromium texture would add input, scaling, popup, clipboard and accessibility routing; its feasibility was not demonstrated here.
- LSP is optional for all useful first versions. Coloring, indenting, find, save and undo can work without a Julia server. Diagnostics/completions require document versions, positions, cancellation and synchronization; a marker API alone is not a language service.

### Gaps

- No current numeric startup, memory, typing-latency or file-size benchmark is available for these components in this app. Upstream claims about large files are not DataBrowser measurements.
- Julia syntax coloring in the goossens option needs a custom definition, including nested block comments, triple-quoted strings, interpolation, macros, Unicode identifiers and operator conventions. CodeMirror's official legacy Julia mode exists; no modern Julia parser package or Monaco Julia tokenizer was validated here.
- Zep's README says its UTF-8 support is incomplete and provides editing-mode unit tests, but current coverage of combining marks, non-BMP characters, IME, grapheme movement and the resolved ImGui ABI remains unverified. — [Zep README](https://raw.githubusercontent.com/Rezonality/zep/master/README.md).
- Upstream development activity is established for goossens by its documented April 2026 rewrite and current ImGui support, and for Scintilla by current releases. This survey did not establish exact latest commit dates or release promises for each project.
- Whether CodeMirror or Monaco is preferable on macOS WebKit, Linux WebKitGTK and Windows WebView2 requires a real integration trial; browser feature support is not proof of host parity.

## What should be built first, and what should be deferred?

### Takeaway

First establish the no-restart CSV-plus-other-data workflow through the current public API and measure the missing operations. Then add a generic read-only text visualizer. If the goal is useful project-file editing, a bounded native multiline experiment can answer interaction questions, but a goossens binding is a more credible next step for durable file tabs and undo. Saving code and applying code to the live workspace must be separate visible operations.

### Cited Findings

- DataBrowser's vision already requires a non-blocking REPL and live project-code/workspace updates. — [vision.md:85](/Users/davide/code/Julia/DataBrowser-dev/docs/vision.md:85).
- The roadmap identifies the current need for shared public application operations and source-file actions. — [roadmap.md:397](/Users/davide/code/Julia/DataBrowser-dev/docs/roadmap.md:397), [roadmap.md:430](/Users/davide/code/Julia/DataBrowser-dev/docs/roadmap.md:430).
- External VS Code can open a specific file/line directly through its existing command line. This is an immediate aid to the user's external-editor-or-REPL experiment, while the in-app editor is investigated. — [VS Code CLI](https://code.visualstudio.com/docs/configure/command-line).

### Inferences

The following are proposed scope and acceptance checks, not claims about present APIs.

**Read-only mode:** accept a text document with identity/version, label, media/language hint and text content, through public access. Retain immutable content and a line-offset index. Start with fixed-height lines, horizontal scrolling, optional line numbers, Copy All and Copy Line/Selection controls, find/next/previous, and an explicit loading/error state. For long files, index once per document version and draw visible lines. For a giant individual line, provide a bounded/chunked rendering strategy with a visible indication; a row clipper alone is insufficient. Add character-range selection deliberately rather than implying that plain rows behave like an editor.

**Small editing experiment:** one source document, editable buffer, visible dirty state, Save, Reload/Revert, close-with-dirty handling, clear file identity, and a short path back to the same live workspace. Keep Save distinct from Apply/Refresh. Do not silently save on focus loss or evaluate on keystrokes. Preserve line endings, encoding/BOM policy and final newline. Detect an externally changed file before overwriting it. A successful save should stay successful even if later Julia loading fails.

**Useful source editing after the experiment:** persistent per-document undo, line/column navigation, find/replace, indentation/comment shortcuts, Julia coloring, error location navigation, and normal macOS/Windows/Linux clipboard and modifier behavior. A richer editor widget should own document editing state; the app should own source identity, save/conflict handling and project-code application. This boundary permits the viewer and editor to evolve independently.

**Keep the user's running app:** begin the session with Revise loaded, keep named recipe functions in external source files or define methods in the REPL, and change one callback at a time using public registration functions. The exact Revise and DataBrowser registration/reload commands must come from the current public API workflow audit, not from speculative editor code. The text component should not introduce a restart requirement or an implicit full-IDE task.

**Defer:** debugger, terminal, package manager, Git UI, AI completion, minimap, collaborative editing, generic document editing, and an in-app Julia LSP host until the short-recipe workflow demonstrates a need. Optional language coloring should not require LSP.

Acceptance tests before recommending an editing component:

1. Open text payloads from data items and, once public access exists, source items; do not read cache or UI fields.
2. Load/save byte-exact unchanged UTF-8; test LF, CRLF, empty file, final newline, BOM and an explicit policy for invalid UTF-8/NUL bytes.
3. Type, paste, select, move over, delete and undo `α`, `μ`, `∂`, combining `á`, non-BMP mathematical `𝛼`/`𝒜`, emoji and CJK. Distinguish byte preservation from glyph rendering and character entry.
4. Test Chinese/Japanese/Korean composition, candidate placement, dead keys, AltGr, Swedish keyboard punctuation, Command shortcuts and detached viewports on each supported OS.
5. Edit A, activate Find, edit B, return to A, and undo. This specifically tests whether undo is a document capability rather than an incidental focused-widget state.
6. Confirm selection/copy, search across lines, replace undo, tab indentation, nested Julia comments and triple strings.
7. Exercise small files, many short lines, a multi-megabyte single line, and a large log. Measure open time, retained memory, frame/typing latency and search cancellation. Set product limits only from these results.
8. Simulate external save, deletion, failed save and failed code application; preserve unsaved content and distinguish saved source from loaded code.
9. Verify all app actions are public operations; no editor, recipe or agent may mutate private workspace/cache/job/UI state.
10. Test artifact startup on clean supported macOS, Linux and Windows environments, including shared-library context/version checks and license notices.

### Gaps

- The user may prefer an immediately useful code editor over a temporary multiline experiment. A native multiline prototype is reversible, but the survey should not turn it into a default permanent architecture.
- The shortest working CSV-plus-other-type recipe, live method replacement and explicit refresh semantics must be proven separately. A component choice cannot solve missing project-code invalidation or source-stage materialization.
- No code changes, dependencies or tests are required for this survey. The next concrete implementation item is a public visualizer/document contract plus a small acceptance prototype, after the user reviews the workflow evidence.
