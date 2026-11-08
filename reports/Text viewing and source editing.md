# Add text inspection and live editing

The real SuperGaN data already opens with the CSV recipe and no custom loader, item type, or drawing code. **The browser can stay open while project functions change**, provided the user explicitly rebuilds the existing workspace after updating methods or registrations. A useful text viewer and an editor for project code fit this workflow, but neither is a supported public feature today. The first implementation should supply text payload delivery, read-only text visualization, and project-file editing through public operations. Source preview needs a separate access path so it still works when a parser fails or no recipe recognizes the file. Saving code, loading code, and recomputing data must remain distinct observable steps.

## Open the real data with seven statements

Run this in the DataBrowser environment:

```julia
using Revise
using DataBrowser

data = "/Users/davide/Library/CloudStorage/OneDrive-LundUniversity/projects/Lind/SuperGaN/data"
project = define_project("SuperGaN")
register_csv!(project; read_options=(comment="#",))
workspace = open_workspace(project, data; cache=false)
gui = open_browser(workspace; wait=false)
```

These are the public operations used in the [real startup script](<../research_notes/Text viewing and source editing/supergan_live.jl>). `using DataBrowser` already brings the Recipes functions into scope. `wait=false` keeps the caller available for more Julia commands, including when the lines run as a script. This experiment used `cache=false` to keep generated cache data temporary; the persistent-cache variant has not been validated for code changes. Normal browser view-state persistence remains enabled and can write `databrowser.toml` in the data root; measurement files were only read. Environment setup and the extra commands used to select a repeatable screenshot target are not project boilerplate. The [CSV recipe](../lib/DataBrowserRecipes/src/premade.jl) supplies both extension detection and parsing; the [browser lifecycle](../lib/DataBrowserGUI/src/Gui/Layout.jl) supplies the nonblocking session.

The CSV recipe now supplies the filename, including its extension, as the default item label. No label callback is needed in project code. A supplied `label=(data, metadata) -> ...` overrides it; `label=nothing` uses the item ID. The generic item-label default remains the stable ID. This follow-up was applied to the same running SuperGaN browser through Revise and a workspace rebuild; see the [updated screenshot and checks](<../research_notes/Text viewing and source editing/supergan-evidence.md#default-filename-label-applied-without-restarting>).

**The directory contains 59 CSV files and 59 PNG files; this registration publishes 59 data items.** Each CSV starts with `#` metadata comments, so the read option is necessary. The browser shows the data-item hierarchy using the source directories. Select a CSV item, then open **Inspect → Table Inspector** to see its columns and rows. The verified selected measurement was `exp_raw/72b/L/Transistor/C1_2um/72b_L_Transistor_C1_2um_20261009_194743_IVSweep.csv`. Its table has 199 rows and the columns `Voltage_V`, `Current_High_A`, `Current_Low_A`, `Time_sec`, and `Status`; its status values are all zero. These observations concern that measurement, not every CSV in the folder. See the [actual source file](</Users/davide/Library/CloudStorage/OneDrive-LundUniversity/projects/Lind/SuperGaN/data/exp_raw/72b/L/Transistor/C1_2um/72b_L_Transistor_C1_2um_20261009_194743_IVSweep.csv>) and the [Table Inspector](../lib/DataBrowserGUI/src/Gui/TableInspector.jl).

![Actual SuperGaN browser with the C1_2um measurement selected and its source metadata visible](<../research_notes/Text viewing and source editing/supergan-baseline.png>)

This is the actual running app. **Selecting data alone leaves the main viewing area blank:** Table Inspector starts closed and must be opened from the Inspect menu. The screenshot shows the selected real measurement, its filename and timestamp, and the empty viewing area. A lazier initial state should show a suitable built-in view when an item is selected.

The two imports alone do not open a folder or install automatic format recognizers. The user still defines a project and registers CSV support; no integrated source editor appears. The resulting browser is a data browser rather than a general file explorer. Unread source files can appear as gray tree rows while discovery proceeds. A PNG with no matching recipe produces no data item after interpretation; it does not automatically open as an image or text. There is also no automatic IV plot in this baseline. The table view works with the imports above; plots require the optional plotting backend. This is useful immediately, but the missing source preview prevents inspection of files that are unrecognized or fail to parse. The [read/expand routing](../lib/DataBrowserRecipes/src/stages.jl) and [tree behavior](../docs/ARCHITECTURE.md) explain this distinction.

## Change functions without closing the browser

The smallest useful addition is one named function and two public calls. For example, count the points in each actual IV table:

```julia
analyze_iv(table, _) = Dict(:points => length(table.Voltage_V))
register_csv!(project; read_options=(comment="#",), analyze=analyze_iv)
modify_workspace!(workspace; rebuild=true)
```

Evaluate these statements line by line in the same Julia session. The first defines the analysis. The second replaces the CSV registration. The third rebuilds the same workspace, leaving the browser attached to it. **Preserve `read_options=(comment="#",)` whenever replacing this recipe:** registration replaces the whole recipe rather than changing only the supplied field. Labels, collection placement, processing, and analysis are optional; ordinary Recipes users do not need to construct an item type. These are the current [registration contract](../lib/DataBrowserRecipes/src/registration.jl) and [workspace rebuild contract](../lib/DataBrowserCore/src/Workspace/Operations.jl).

Once `analyze_iv` is registered, change its method and rebuild. Repeating the registration is unnecessary if its wiring and options stay the same:

```julia
analyze_iv(table, _) = Dict(:points => length(table.Voltage_V), :maximum_current_uA => maximum(table.Current_High_A) * 1e6)
modify_workspace!(workspace; rebuild=true)
```

**The actual SuperGaN check returned `points => 199`, then `maximum_current_uA => 6.1025` after a saved-file method revision and rebuild without re-registration.** The workspace and browser session identities stayed the same, all five measured columns remained intact, and the Julia process did not restart. This maximum is a direct summary of the selected high-terminal current column, without a fitted or physical interpretation. The real test used the tracked helper file below, not a custom launcher. See the [helper](<../research_notes/Text viewing and source editing/iv_analysis.jl>) and [runtime evidence](<../research_notes/Text viewing and source editing/supergan-evidence.md>).

![The same actual SuperGaN browser after applying the analyzer, with maximum_current_uA 6.1025 and points 199 visible in the Information Panel](<../research_notes/Text viewing and source editing/supergan-analysis.png>)

Compared with the baseline above, the Information Panel now shows **`maximum_current_uA = 6.1025` and `points = 199`** for the same measurement. This is the actual result after applying the analyzer in the still-running app. The analyzed state remains open; every measured table value is unchanged.

VS Code's “execute selection/line” workflow needs no wrapper. Send the function definition and registration to the same Julia session, then run the rebuild line. A later edit to the named function needs the updated definition and rebuild. To work by saving a file instead, put only the function definition in `analysis.jl`. Evaluate this line first:

```julia
includet("analysis.jl")
```

Then evaluate the registration and rebuild:

```julia
register_csv!(project; read_options=(comment="#",), analyze=analyze_iv)
modify_workspace!(workspace; rebuild=true)
```

After saving a method change in that tracked file, evaluate:

```julia
Revise.revise(; throw=true)
```

Then, in the next REPL evaluation:

```julia
modify_workspace!(workspace; rebuild=true)
```

The real test tracked `research_notes/Text viewing and source editing/iv_analysis.jl` this way, saved the maximum-current addition, explicitly revised it, and rebuilt. The first harness attempt combined `includet` and rebuild in one `begin` block and hit Julia's “method too new” error. Running the rebuild in the next REPL evaluation recovered without restarting. **Let `includet` or `Revise.revise` finish before the separate evaluation that rebuilds the workspace.** This is an ordinary line-by-line workflow, with no latest-method wrapper.

Revise's default `includet` behavior updates methods; it does not replay ordinary top-level assignments or registration calls. If the registration itself changes, execute that registration again before rebuilding. `using Revise` alone does not track an arbitrary project file. Keeping startup separate from the method file also avoids reopening a workspace and browser whenever the file is evaluated. These behaviors are documented by [Revise](https://timholy.github.io/Revise.jl/stable/user_reference/) and [Julia code loading](https://docs.julialang.org/en/v1/manual/code-loading/#Definitions).

There are three states: **saved source, loaded methods/registration, and current pipeline results**. Editing a file affects the first. Evaluating code or revising methods affects the second. Rebuilding requests the third. The source watcher follows data-file changes; it does not apply project code. Cache identity currently uses the project name and source identity rather than a project-code fingerprint, so changing code alone can leave successful or failed results stale. Automatic invalidation is explicitly unfinished in the [roadmap](../docs/roadmap.md).

The explicit rebuild is coarse: it starts a new workspace runtime and workers while retaining the workspace object. A failed rebuild leaves that workspace closed. It is therefore a usable current refresh command, not a complete recoverable “Apply code” operation. Existing long-running callbacks should not be assumed to see every new method automatically; live plot callback changes were not verified. Ordinary method edits support the intended no-restart workflow, while Julia type-layout changes and some module changes remain [Revise limitations](https://timholy.github.io/Revise.jl/stable/limitations/). A literal promise that arbitrary Julia changes never require a new process exceeds current Julia support; that boundary need not complicate short recipe functions.

## Select a value before choosing its visualizer

The viewing mode should follow the selected data and stay read-only. The editing mode should follow the selected project code file. A text-valued analysis result has no necessary writable file, and the selected measurement must not become an editing target merely because it can be displayed as text. The [vision](../docs/vision.md) already distinguishes data sources, items, project code, workspaces, and visualizers. It also requires visualization to be a capability over data rather than a special data model.

The current public data path delivers processed items and, eventually, the latest collection-produced version. `materialize_items(workspace, items)` waits for item processing and requests analysis and ancestor collection work; it does not wait for all collection processing. `read_item_data` extracts payloads from those items. Neither accepts a pipeline-stage selector. A later materialization can therefore expose a newer collection result. A text visualizer should receive the chosen payload through public access, just as a table or plot does, rather than discover job or cache state itself. See the [data access contract](../lib/DataBrowserCore/src/Workspace/DataAccess.jl).

Four values must remain distinguishable: source bytes, the `read` result, an expanded item, and a processed item. For the CSV recipe, `read` returns a parsed table, not the original CSV text. With a multi-entry file, one source can create many items; moving to source preview should show that source once and retain which selected items led to it. An analysis result should appear with the metadata produced by that operation. The planned [pipeline inspection feature](../docs/roadmap.md) already places this choice in shared application access so each visualizer need not implement its own pipeline logic.

**Source preview must work before a semantic reader succeeds.** Otherwise the user cannot inspect the malformed CSV that caused the error, or a text file no recipe recognizes. It should not insert a fabricated data item or call the project's parser just to display raw input. Directory files have a documented public `SourceFile.filepath`, suitable for an explicit file reader; a database row, archive member, or stream need not have one. A general preview should use a source capability that returns suitable text or bytes, identity, revision, and whether content is complete or truncated. This is a proposed requirement, not a currently callable preview API. See the [source contract](../lib/DataBrowserSources/src/directory_source.jl) and [stage contract](../lib/DataBrowserAPI/src/stage_contract.jl).

There is a more immediate prerequisite: **a plain `String` currently fails during processed-payload storage**. `register_item!` needs only a reader, so reading a directory text file can be as small as `file -> read(file.filepath, String)`. A diagnostic reader returned Unicode text containing CRLF and blank lines. The item was discovered, but `read_item_data` failed with `ArgumentError: 'String' iterates 'Char' values, which doesn't satisfy the Tables.jl AbstractRow interface`. The store asks Tables.jl for columns before a visualizer can consume the string. `cache=false` does not avoid this path: it selects an in-memory DuckDB, not a general arbitrary-value store. The [processed payload store](../lib/DataBrowserCache/src/project_cache_domain.jl) and [table encoding](../lib/DataBrowserCache/src/cache_buffer.jl) substantiate the failure.

Returning `(text=readlines(file.filepath),)` succeeded as a four-line table and retained the Unicode content and blank line. It discarded line delimiters, and the Table Inspector formats strings as cell values and truncates long cell displays to 90 characters. This is a diagnostic workaround, **not a text viewer**. A first text feature must allow a suitable string to reach a visualizer without encoding it as a table. Unsupported payloads remaining inspectable and uncached is the intended [vision](../docs/vision.md), not current demonstrated behavior.

For small text values, a string plus document identity and revision is enough. A shipped file-text recipe should choose and report decoding, distinguish binary-looking content, and preserve source-code line endings. Large files need bounded acquisition as well as efficient drawing: `read(file, String)` loads the whole file, `readlines` allocates line strings, and current materialization waits synchronously. A later range-based content capability can handle logs and large sources without complicating ordinary string recipes. Exact stage-output references and metadata provenance also remain unfinished [cache work](../docs/roadmap.md); a viewer must not imply a historical result is exact based only on an item ID.

## Prefer a native component for the first editor

The desktop uses Dear ImGui through CImGui, GLFW, and OpenGL3. This checkout resolves CImGui 8.0.0 against ImGui 1.92.8-docking. Native ImGui components fit the current rendering and docking model; a web editor adds a browser host as well as a widget. The comparisons below use inspected interfaces and upstream documentation. **No candidate editor was installed, bound, benchmarked, or integrated into DataBrowser.** Integration effort is an engineering judgment, not measured delivery time. See the [resolved environment](../Manifest.toml) and [GUI setup](../lib/DataBrowserGUI/src/Gui/Layout.jl).

| Component | What it provides | Main integration issue | Recommendation |
|---|---|---|---|
| ImGui rows with `ImGuiListClipper` | Efficient submission of visible fixed-height lines. | App supplies line index, selection/copy, search, and wrapping. | First read-only viewer. [Header](https://raw.githubusercontent.com/ocornut/imgui/v1.92.8-docking/imgui.h) |
| `InputTextMultiline` | Existing Julia wrapper; editing, clipboard, undo, read-only and wrap options. | Focused-widget input state does not provide durable undo per file tab. | Bounded single-file experiment. [Implementation](https://raw.githubusercontent.com/ocornut/imgui/v1.92.8-docking/imgui_widgets.cpp) |
| goossens ImGuiColorTextEdit rewrite | Persistent editor objects; undo, find/replace, coloring, folding, markers; stated ImGui 1.92.8/1.92.9 support. | C++ binding/artifact and Julia coloring required; Unicode follows ImGui configuration. | Strongest native candidate to trial. [Project](https://github.com/goossens/ImGuiColorTextEdit) |
| Original/forked ImGuiColorTextEdit | Established coloring/undo; forks add editing features. | Original and santaclose documentation acknowledge slow regex coloring for many languages. | Consider only against a concrete rewrite limitation. [Original](https://github.com/BalazsJako/ImGuiColorTextEdit), [fork](https://github.com/santaclose/ImGuiColorTextEdit) |
| Zep | ImGui renderer, standard/Vim modes, buffers, splits, search and markers. | Upstream calls UTF-8 incomplete; current ABI and Julia support unverified. | Consider if modal editing matters. [Project](https://github.com/Rezonality/zep) |
| CodeMirror 6 | Modular editing, accessibility, bidi support, virtualized documents; Julia legacy mode. | DOM/webview and Julia–JavaScript document synchronization. | Preferred web trial if adopting a browser host. [Features](https://codemirror.net/), [Julia mode](https://github.com/codemirror/legacy-modes/blob/main/mode/julia.js) |
| Monaco | VS Code editor component with models, providers, markers, folding and accessibility. | Browser assets, workers and bridge; VS Code extensions do not simply run in Monaco. | For a deliberate richer web IDE direction. [Project](https://github.com/microsoft/monaco-editor) |
| Scintilla/Lexilla | Mature native editing, undo, search, IME support and Julia lexer. | Cocoa/GTK/Win32/Qt control embedding and focus rather than ImGui drawing. | Poor first fit for this shell. [API](https://www.scintilla.org/ScintillaDoc.html), [Julia lexer](https://github.com/ScintillaOrg/lexilla/blob/master/lexers/LexJulia.cxx) |
| External VS Code | Useful editing now; file/line handoff via `code --goto`. | Separate application; does not deliver in-app writing. | Keep available during the experiment. [CLI](https://code.visualstudio.com/docs/configure/command-line) |

A clipped line viewer is the smallest durable viewing component, but clipping rows does not implement text selection and does not bound a very long individual line. Start with fixed-height lines, horizontal scrolling, line numbers, copy, find/next/previous, and clear loading/error states. Wrapping introduces variable-height layout. A huge single line needs bounded rendering or chunking independently of row clipping. [Dear ImGui's clipper contract](https://raw.githubusercontent.com/ocornut/imgui/v1.92.8-docking/imgui.h) makes those limits explicit.

Native multiline can test whether editing a short recipe inside the app feels useful. It already has input and clipboard behavior, but it is not a full file editor. ImGui maintains one current input state; activating another input can replace the state that held undo. Switching tabs or activating Find can therefore expose the limitation immediately. The pinned implementation uses UTF-8 edit state and rebuilds a line index; it should not be described as a fully virtualized editor or as necessarily converting the whole document to UTF-16. [Pinned widget source](https://raw.githubusercontent.com/ocornut/imgui/v1.92.8-docking/imgui_widgets.cpp)

For useful file tabs, trial the goossens rewrite with one persistent editor object per document. A small C ABI should expose create/destroy, text load/retrieval, draw, dirty revision, cursor/selection, and markers. It must use the same ImGui implementation and build configuration as CImGui; ImGui does not guarantee shared-library ABI compatibility. No maintained Julia binding was established here, and the inspected language definitions do not include Julia. The widget is MIT licensed; packaging and Julia syntax rules remain real work. [Editor header](https://github.com/goossens/ImGuiColorTextEdit/blob/master/TextEditor.h), [ImGui ABI guidance](https://github.com/ocornut/imgui/blob/master/imgui.h)

Unicode is an acceptance issue for scientific Julia code. The installed macOS binding uses 16-bit `ImWchar`, and the rewrite documents the resulting BMP restriction. This affects non-BMP mathematical characters and emoji input/display; it does not prove an untouched UTF-8 buffer will be rewritten on save. Test Greek identifiers, combining marks, non-BMP symbols, CJK composition, dead keys, Swedish punctuation, and platform shortcuts. GLFW forwards characters and clipboard, but candidate-window positioning and composition parity are unverified in this stack. Changing to a 32-bit Unicode build is coordinated artifact/ABI work. [Rewrite Unicode documentation](https://github.com/goossens/ImGuiColorTextEdit), [GLFW backend](https://github.com/ocornut/imgui/blob/v1.92.8-docking/backends/imgui_impl_glfw.cpp)

CodeMirror or Monaco can supply richer editing, but require browser lifecycle, focus, clipboard, document versions and position mapping. CodeMirror counts UTF-16 code units, unlike Julia string indexes. A webview uses WebKit on macOS, WebKitGTK on Linux, and WebView2 on Windows; a separate window is simpler than compositing it inside a detached ImGui viewport, but changes the interaction. Syntax coloring needs no language server. Completion and diagnostics can follow after saving and applying recipes work. [CodeMirror guide](https://codemirror.net/docs/guide/), [webview platforms](https://github.com/webview/webview), [Monaco integration](https://github.com/microsoft/monaco-editor)

## Shared visualizer windows: current status

The foundations exist, but a shared project window model does not. The public `register_plot!` API
registers several named plots for an item kind. Its `setup(workspace, items)` callback creates a
figure and `draw(workspace, items, figure)` fills it using already processed items. The plotting
extension owns a main window and additional windows; each can follow the workspace selection or
retain fixed item IDs. It persists window IDs, titles, plot choices, and selection associations in
`databrowser.toml`. It does not persist arbitrary visualizer settings or figure contents.

Tree, item selection, metadata, and table inspection still use dedicated browser panels. Internal
GUI extension hooks provide drawing, menus, and save/load callbacks, but are not public. Existing
ImGui docking does not provide named project tabs that each restore a collection of windows and
their selection relationships. See [plot window state](../lib/DataBrowserPlots/ext/DataBrowserPlotsGLMakieExt/PlotState.jl),
[plot persistence](../lib/DataBrowserPlots/ext/DataBrowserPlotsGLMakieExt/PlotsExtension.jl), and the
[fixed initial layout](../lib/DataBrowserGUI/src/Gui/Layout.jl).

The proposed shared model has three parts: a reusable visualizer; a saved project window with its
input, chosen visualizer, and settings; and a workflow tab containing windows, their arrangement,
and their selection links. The same input can appear in several windows with different visualizers.
The saved window definition should be separate from its live GUI resources. Tree and item-list
visualizers must be able to publish selections that other windows follow. Saving this configuration
is shared behavior; exporting a plot, table, or text file depends on the visualizer's capabilities.

This is a proposed direction, not an implemented public API. A useful first step would give the
table and plot views the same public window operations and persistence, then move the existing
selection and metadata panels onto that model. The project's saved main window could then remember
the user's visualizer choice, with a suitable built-in default for a previously unseen input.

## Add the missing public operations in reviewable steps

The app should expose separate **Data** and **Project code** navigation. Data views follow items or source previews and offer read-only inspection. Code views follow declared project files and retain buffers when data selection changes. `define_project("SuperGaN")` currently supplies a name, not an entry file or editable code root. Project-file declaration and document operations are therefore required; the data-source directory must not silently become the editable project root. The planned [project configuration](../docs/roadmap.md) can eventually record this association.

A lazier initial experience would offer built-in CSV recognition and a read-only source preview when opening a directory, then let one ordinary function extend that behavior. The project could explicitly associate the small analysis file that the editor opens. This would remove setup users currently write without hiding a second project framework. It is proposed behavior: the seven statements above remain the current public startup path.

An extension must be able to implement both modes through public operations. `GuiExtension` and `register_gui_extension!` exist internally but are not exported; publishing a supported surface is unfinished [roadmap work](../docs/roadmap.md). Qualified access to these implementation names is not a public workaround. The smallest contract should open/manage visualizer windows, obtain selected public results, and open/save project documents without exposing browser, catalog, cache, or worker fields. Existing `register_plot!` callbacks are a plotting contract, not a general text-editor host.

The document layer owns one buffer per file, saved baseline, dirty state, encoding/newline policy, and external-change detection. Save should preserve unchanged bytes where promised, write fully before replacing the file, and leave the buffer dirty on failure. A clean buffer can reload an external edit; a dirty buffer needs a conflict choice that preserves both versions. Switching files, searching, and opening an error location must retain per-document undo and unsaved edits. The widget owns editing mechanics; the application owns file identity and persistence.

**Save writes text; Apply updates code and requests fresh data.** Start with explicit actions. Show saved-but-not-applied, applied-and-updating, current, apply failed, and data failed as different states. Current must mean results were published for the applied code revision, not simply that the queue is idle. An Apply operation should handle named methods and changed registrations, report file/line information where available, invalidate both successful and failed results, and prevent old worker outputs from being labeled current. Start conservatively with project-wide invalidation, matching the [code-fingerprint roadmap](../docs/roadmap.md), before trying per-function dependency tracking.

Julia evaluation can have partial side effects, so Apply cannot promise arbitrary rollback. A syntax/load failure, a save failure, and a data-processing failure require separate errors. Current workspace messages and console backtraces do not form a structured IDE problem list. Error records should retain operation, item/source identity, file/line when known, and full details; navigating to one should preserve open edits. Apply on Save becomes a later preference after explicit Apply is dependable.

| Reviewable item | Acceptance evidence |
|---|---|
| No-restart experiment, verified | Real SuperGaN baseline and updated metadata are shown above; public checks establish saved-file revision and unchanged measurements in the same browser. Next, show a suitable default view and verify recovery from an analysis error and live plot-function changes. |
| Deliver text payloads and a public viewer host | A string-producing recipe materializes successfully without a line-table workaround; a viewer uses only documented public operations. |
| Add read-only text and source preview | Full copy/find/navigation; explicit encoding and truncation; malformed/unrecognized source still inspectable; source siblings coalesce. |
| Add project documents and a useful editor | Declared code files; save/reload/conflict handling; undo survives A → Find → B → A; data selection cannot discard code edits. Trial the native editor before committing to it. |
| Add public Apply and code-aware invalidation | Named-method and registration edits refresh the same browser; failures remain recoverable; result revisions correspond to applied code; no private state access. |

Before choosing an editor, test LF/CRLF, empty files, final newline, BOM, invalid UTF-8, long lines, large logs, external deletion/save, and failed writes. Measure open time, retained memory, typing/frame latency, and search responsiveness in the actual app. Test clean artifact startup on supported macOS, Windows, and Linux systems. Defer debugger, terminal, package manager, Git interface, completion, and language-server hosting until short recipe editing shows a need. These are proposed acceptance checks. The initial survey installed no dependencies or editor components. The subsequent CSV label change passed the Recipes package suite, 15/15 tests.

**Validation:** the real SuperGaN app remains open with the analyzer and default filename labels applied. All three actual screenshots target the same DataBrowser window; public checks confirm the same workspace, browser session, and Julia process throughout. The saved-file Revise update passed, and every measured table value remained unchanged. Recovery from the observed method-age error passed; a deliberately failing analysis callback and live plot-method revision remain untested. The only package implementation change is the CSV recipe's default label.
