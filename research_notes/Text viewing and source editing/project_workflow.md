# Project source editing and the shortest public workflow

Survey date: 12 October 2026. This note describes current behavior separately from proposed behavior. No DataBrowser private operation was invoked. Links point to the inspected checkout; line ranges in link labels identify the evidence. Pictures show the actual running SuperGaN project.

## What can the user run now, without restarting the app?

### Takeaway

The current public API supports a short CSV project and rebuilding the same workspace after changing its registrations. The API researcher verified that recipe replacement plus `modify_workspace!(w; rebuild=true)` changes returned data while the same browser session remains usable. It does not currently load project code, revise it, or invalidate cached data automatically when a code file changes. The real-data run now uses the user's SuperGaN directory; screenshots of that running app are the primary visual evidence.

### Cited Findings

- The complete simple CSV example is `using DataBrowser`, `define_project`, `register_csv!`, `open_workspace`, and `open_browser`. It has no custom item types, GUI state, background-job code, or cache manipulation. — [CSV example, lines 1–12](/Users/davide/code/Julia/DataBrowser-dev/examples/01_simple_csv/project.jl:1)
- `register_item!` requires only `read`. `detect` defaults to accepting everything; labels, identity, collection placement, processing, and analysis are optional. Named or unnamed re-registration replaces the previous registration in place. — [Registration docstring and signatures, lines 45–83](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserRecipes/src/registration.jl:45)
- `register_csv!` supplies detection and reading, parses into a DataFrame, forwards the other callbacks, and chooses the first matching registration in registration order. Its default extension is `.csv`. — [CSV recipe contract, lines 25–65](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserRecipes/src/premade.jl:25)
- `modify_workspace!` is exported. Its documented behavior is to rebuild the same project in place; omitted settings stay unchanged. It cannot replace the project object. A failed rebuild leaves the workspace closed. — [Public exports, lines 15–39](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserCore/src/DataBrowserCore.jl:15); [rebuild contract, lines 54–68](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserCore/src/Workspace/Operations.jl:54)
- The source watcher notices added, changed, and removed data files and metadata changes. Source fingerprints use path, file size, and modification time; this is a data-source watcher, not a project-code reload feature. — [Directory fingerprints, lines 24–31 and 117–126](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserSources/src/directory_source.jl:24); [directory watcher, lines 347–391](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserSources/src/directory_source.jl:347)
- Current cache identity lacks project code. The roadmap explicitly says changing project code can reuse stale results and leaves automatic successful/failed-result invalidation, Revise integration, and a persisted fingerprint unfinished. — [Roadmap, lines 272–276](/Users/davide/code/Julia/DataBrowser-dev/docs/roadmap.md:272)

### Inferences

Run this from the normal DataBrowser environment on the real SuperGaN data. `wait=false` keeps the REPL available even when these lines are executed as a script:

```julia
using Revise
using DataBrowser

p = define_project("SuperGaN")
register_csv!(p; read_options=(comment="#",))
w = open_workspace(p, "/Users/davide/Library/CloudStorage/OneDrive-LundUniversity/projects/Lind/SuperGaN/data"; cache=false)
b = open_browser(w; wait=false)
```

The directory contains 59 CSV files and 59 PNG files, as inventoried by the API researcher. Each CSV has `#` metadata comments before its header, so the read option matters. This recipe recognizes the CSV files and gives each one a table item; it does not supply an image viewer for the PNG files or a general text viewer. `cache=false` keeps generated cache data temporary and does not solve unsupported payload types. The existing table inspector is the useful baseline. [Real run script](</Users/davide/code/Julia/DataBrowser-dev/research_notes/Text viewing and source editing/supergan_live.jl:1>), [real CSV header, line 25](/Users/davide/Library/CloudStorage/OneDrive-LundUniversity/projects/Lind/SuperGaN/data/exp_raw/719a/L/quantumdots_C1/QD/719a_L_quantumdots_C1_QD_20261009_190704_IVSweep.csv:25), [CSV detection](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserRecipes/src/premade.jl:30), [table-inspector menu](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserGUI/src/Gui/TableInspector.jl:98)

Add one named function in the same REPL, keeping all measured table columns intact:

```julia
analyze_iv(data, _) = Dict(:points => length(data.Voltage_V))
register_csv!(p; read_options=(comment="#",), analyze=analyze_iv)
modify_workspace!(w; rebuild=true)
```

This counts the actual `Voltage_V` column and adds `points` metadata. It changes no source file and makes no physical interpretation of the IV curve. Preserve `read_options` when replacing the registration: re-registration replaces the whole recipe, rather than patching only its `analyze` field. The named-method/Revise part of this exact sequence remains a separate runtime check. The already verified same-session rebuild used a replacement process callback and observed changed numerical output. [Real CSV header](/Users/davide/Library/CloudStorage/OneDrive-LundUniversity/projects/Lind/SuperGaN/data/exp_raw/719a/L/quantumdots_C1/QD/719a_L_quantumdots_C1_QD_20261009_190704_IVSweep.csv:25), [whole-recipe replacement](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserRecipes/src/registration.jl:75), [rebuild contract](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserCore/src/Workspace/Operations.jl:54)

For a VS Code file, put just the helper definition in `analysis.jl`, load it once with `includet("analysis.jl")`, and evaluate the registration above. After editing and saving the helper, the simple explicit sequence is:

```julia
Revise.revise(; throw=true)
modify_workspace!(w; rebuild=true)
```

`includet("analysis.jl")` tracks method edits. It does not by default replay top-level data assignments or registration calls, and does not recursively track included files. Therefore editing `register_csv!(p; analyze=...)` in a file requires evaluating that registration again. A plain `using Revise` alone is not an apply-project operation. [Revise user reference](https://timholy.github.io/Revise.jl/stable/user_reference/)

The proposed embedded editor should expose this same sequence as an application operation. It should not run the entire entry script every save: that script may open another workspace/browser, and Julia evaluates an included file again each time it is included. [CSV example startup](/Users/davide/code/Julia/DataBrowser-dev/examples/01_simple_csv/project.jl:11), [Julia code inclusion](https://docs.julialang.org/en/v1/manual/code-loading/#Definitions)

### Gaps

- The API researcher owns the exact same-session runtime outputs and real-app screenshots. Named methods defined after GUI startup and revised from a saved file require their separate runtime check; they must not be inferred from replacement-closure success.
- There is no current public operation for declaring the project entry file or listing its editable source files. The script is ordinary Julia code; `define_project("SuperGaN")` receives a name, not a source path. [Current constructor](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserRecipes/src/registration.jl:33)
- The API researcher confirmed a raw `String` payload fails materialization even with `cache=false`; `(text=readlines(file.filepath),)` works as a one-column table. This is a temporary table-inspection path, not a genuine text visualizer. The vision's arbitrary-data goal is not current payload support. [Text experiment source](</Users/davide/code/Julia/DataBrowser-dev/research_notes/Text viewing and source editing/text_recipe_demo.jl>), [Vision, lines 125–141](/Users/davide/code/Julia/DataBrowser-dev/docs/vision.md:125)

## What must saving, loading code, and refreshing data mean?

### Takeaway

These are three distinct states. An editor can save valid text while the running code remains old, and revised code can be loaded while visible data still comes from old cached results. A visible “Saved” indicator cannot mean the data has been refreshed.

### Cited Findings

- Project code is intended to define scientific interpretation while the workspace owns scanning, cache, jobs, and UI state. The GUI and scripts should share workspace operations. — [Architecture, lines 11–20](/Users/davide/code/Julia/DataBrowser-dev/docs/ARCHITECTURE.md:11); [vision shared operations, lines 196–200](/Users/davide/code/Julia/DataBrowser-dev/docs/vision.md:196)
- The existing plan requires relevant code changes to invalidate successful and failed results while open and across reopen. Its finer per-function integration is explicitly still a TODO; the later roadmap recommends starting conservatively at project scope. — [Workspace plan, lines 328–340](/Users/davide/code/Julia/DataBrowser-dev/docs/plans/workspace-graph/workspace-graph.md:328); [current roadmap, lines 272–276](/Users/davide/code/Julia/DataBrowser-dev/docs/roadmap.md:272)
- Materialization returns processed items, waits for requested processing, and throws for a failed item. Collection work can complete afterward, producing a newer version on a later read. — [Data access contract, lines 1–15](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserCore/src/Workspace/DataAccess.jl:1)
- Current table and plot views use source/selection/revision values to refresh after workspace data changes. That observes pipeline output changes; it is not a code-file watcher. — [Table inspector, lines 32–46](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserGUI/src/Gui/TableInspector.jl:32); [plot refresh key, lines 320–340](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserPlots/ext/DataBrowserPlotsGLMakieExt/PlotPanel.jl:320)
- `Revise.revise(; throw=true)` raises revision errors; default revision logs them. Revise documents constraints for long-running tasks that were started before a revision, so loading a method is not sufficient evidence that an existing worker calls its newest version. — [Revise user reference](https://timholy.github.io/Revise.jl/stable/user_reference/); [Revise limitations](https://timholy.github.io/Revise.jl/stable/limitations/)

### Inferences

Proposed state model:

| State | User-visible meaning | Required evidence |
|---|---|---|
| Unsaved | The editor differs from the saved file. | Buffer revision differs from its saved baseline. |
| Saved; code not applied | Disk contains this text; runtime may still use older code. | Successful write, no successful apply for this file revision. |
| Code applied; data updating | Registration/method revision succeeded; affected data is being recomputed. | Successful apply plus workspace recomputation request. |
| Current | The visible results use the applied code revision. | Results were published for that code revision. |
| Apply failed | The file was saved, but loading or registration failed. | Structured apply error with path and location when available. |
| Data failed | Code applied, but a read/process/analyze operation failed. | Workspace status/error for the corresponding data and stage. |

Start with explicit Save and Apply actions. Save writes files only. Apply revises/evaluates the relevant definitions and registrations, then requests recomputation using a public workspace operation. Once the code/version contract is implemented and tested, offer Apply on Save as a preference. This does not require app restart, but it does require a public apply boundary that cannot be assembled reliably from current private GUI state. The existing rebuild is an interim public operation, with its documented failure behavior. [Roadmap missing code revision](/Users/davide/code/Julia/DataBrowser-dev/docs/roadmap.md:272), [rebuild contract](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserCore/src/Workspace/Operations.jl:54)

For several edited files, “Apply” must identify a saved file set. Do not silently combine one unsaved buffer with a different saved dependency. Disk writes can be per file; applying code is a separate action. Retain the last visible results as explicitly older results while recomputation is pending, if the public result/version interface permits that. Never label them Current merely because no job is busy. [Vision code fingerprint requirement](/Users/davide/code/Julia/DataBrowser-dev/docs/vision.md:383)

### Gaps

- A project file/code manifest is not implemented. `dbproject.toml` is planned; entry code remains responsible for opening the workspace. Do not invent `ProjectConfig`, `open_project`, or a reload method as working APIs. [Project configuration roadmap, lines 540–554](/Users/davide/code/Julia/DataBrowser-dev/docs/roadmap.md:540)
- No current public structured apply result establishes that all edited files loaded as one consistent code revision. Julia evaluation is not a transactional rollback mechanism. The application must state the result of a failed apply without promising to undo arbitrary user side effects. [Julia inclusion behavior](https://docs.julialang.org/en/v1/manual/code-loading/#Definitions)
- Named methods loaded by Revise and anonymous callback values registered by executing a block require different apply behavior. This must be tested with the shortest recipe scripts, not hidden behind a package constructor.

## How should the viewing and project-source editing modes differ?

### Takeaway

Keep the inspected data selection separate from the editable project files. A data text viewer consumes a payload or an explicit source-preview value and stays read-only. The source editor writes selected project code files; it does not turn the selected measurement file into an editing target.

### Cited Findings

- Data, data-source configuration, project entry code, package code, workspaces, and visualizers are distinct concepts in the vision. Editing data-source configuration does not rewrite the Julia callbacks. — [Vision concepts, lines 106–141](/Users/davide/code/Julia/DataBrowser-dev/docs/vision.md:106)
- `DataBrowserRecipes` consumes the public type API. The roadmap also names the unfinished GUI extension exports; currently `GuiExtension` and `register_gui_extension!` are not available as exported extension hooks. — [Recipes module contract, lines 1–12](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserRecipes/src/DataBrowserRecipes.jl:1); [unfinished exports, lines 215–219](/Users/davide/code/Julia/DataBrowser-dev/docs/roadmap.md:215)
- Pipeline inspection is planned as shared result access: the workspace supplies the selected result; inspectors consume it without learning special pipeline logic. Source-level results need sibling coalescing. — [Pipeline inspection roadmap, lines 526–538](/Users/davide/code/Julia/DataBrowser-dev/docs/roadmap.md:526)
- The current architecture distinguishes a source read from optional expansion into zero or several logical items. Only the read stage receives the source. — [Core flow explanation, lines 145–154](/Users/davide/code/Julia/DataBrowser-dev/docs/ARCHITECTURE.md:145)

### Inferences

The proposed navigation labels are **Data** and **Project code**. These are two capabilities, not an “editable” checkbox on the same selected object.

| Viewing | Editing |
|---|---|
| Follows selected data item or source preview. | Follows a selected project code file. |
| Shows origin, result stage, and data revision. | Shows file path, dirty state, and applied code state. |
| Select/copy/find, line numbers, wrap, large-file range loading. | Select/edit/undo/redo/find/replace, Save, Apply, error navigation. |
| Never writes a measurement file. | Writes only the chosen project source files. |
| Suitable `String`, text-capable custom value, or explicit source-preview result. | Plain file content from the declared project code set. |

Source preview requirements for the pipeline design: distinguish **source bytes**, **read result**, **expanded item**, and **processed item**. A CSV reader returns a parsed table, so its read result is not the original CSV text. One source file may yield many items; source preview should show that file once and preserve which selected item led to it. A failed parser must not make the underlying file impossible to inspect. Remote/custom sources need a capability-based text preview rather than assuming every source exposes a local `filepath`. These are proposed interface requirements, not new APIs. [Read/expand model](/Users/davide/code/Julia/DataBrowser-dev/docs/ARCHITECTURE.md:145), [pipeline inspection roadmap](/Users/davide/code/Julia/DataBrowser-dev/docs/roadmap.md:530)

The shortest recipe code must remain sufficient: a successful text-valued item should open in the generic text viewer without registering a Makie plot or custom GUI panel. If a source preview requires the project to hand-write path extraction and parsing a second time, the app has failed this experiment. [Generic tools and minimum ceremony goals](/Users/davide/code/Julia/DataBrowser-dev/docs/vision.md:27)

### Gaps

- The published GUI extension surface needed for an external editor/viewer prototype is not available yet; do not import private Browser hooks as a workaround. The smallest package change is to document/export a usable extension surface and provide public workspace/result access sufficient for it. [Roadmap](/Users/davide/code/Julia/DataBrowser-dev/docs/roadmap.md:215)
- “Source text” is not universally defined for a database row, stream, generated simulation input, or binary format. Preview capability and size/encoding metadata must be explicit.
- The set of editable files must come from a declared project code root/file set, not from the data-source root. The current API has no such declaration. [Constructor](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserRecipes/src/registration.jl:33)

## What is the minimum useful editor, including conflicts and errors?

### Takeaway

The first editor can be small: files, tabs, normal text editing, reliable Save, explicit Apply, and useful errors. Save correctness and external-change handling matter before completion, debugging, terminals, or language-server features.

### Cited Findings

- Current workspace status exposes busy/progress/counts/errors for callers. The status contract carries messages, not structured source-code locations and stack frames for IDE navigation. — [WorkspaceStatus contract, lines 194–219](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserCore/src/Workspace.jl:194)
- A failed pipeline stage is logged with exception/backtrace; source failure removes its logical items. The saved/displayed failure message is a string. — [Stage failure handling, lines 74–101](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserCore/src/Workspace/Processing.jl:74)
- The current plot panel shows a short error and directs the user to console details, where the exception/backtrace is logged. — [Plot errors, lines 76–95](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserPlots/ext/DataBrowserPlotsGLMakieExt/PlotPanel.jl:76)
- The roadmap leaves project-code invalidation and a usable extension boundary unfinished. Those are prerequisites for trustworthy embedded Apply and error navigation. — [Code revision](/Users/davide/code/Julia/DataBrowser-dev/docs/roadmap.md:272); [extension boundary](/Users/davide/code/Julia/DataBrowser-dev/docs/roadmap.md:215)

### Inferences

Proposed reversible defaults:

- **Files and tabs:** a project code navigator, one buffer per canonical path, active file tab, and a dirty dot. Clicking a data item must not replace an unsaved code buffer.
- **Editing:** native selection, keyboard movement, cut/copy/paste, undo/redo, indentation, Unicode Julia identifiers, line numbers, find and replace. Syntax colors help; completion, LSP, debugger, and a terminal can wait.
- **Save:** preserve line endings and encoding; record the content baseline when opening/loading. Before writing, compare the current disk version with that baseline. Write through a same-directory temporary file and replace only after the complete write succeeds. A failed save leaves the buffer dirty.
- **External changes:** a clean buffer can reload from disk and keep cursor/selection where possible. A dirty buffer must not be overwritten. Show Compare, Reload from disk, and Keep my changes; the last action needs an explicit conflict decision before replacing someone else's saved version. Focus changes and Save should both recheck the disk baseline. There is one buffer per path even when two app views display it.
- **Two files changed:** Save All reports each write separately. Apply consumes a named saved file set; the code state remains Not applied until the whole requested apply completes successfully.
- **Errors:** distinguish Save failed, Code apply failed, and Data processing failed. Display the data item and pipeline operation for data errors. If a file/line is available, open that location without discarding unsaved edits. Preserve full details for inspection; do not derive a reliable source location by scraping the first message line.
- **Close:** prompt only for dirty buffers and unresolved conflicts. Closing a data view never prompts to save measurement files.

These are proposed editor behavior and acceptance requirements, grounded in the separate-state and public-operation constraints above; they are not current DataBrowser functionality. [Shared workspace operations](/Users/davide/code/Julia/DataBrowser-dev/docs/vision.md:196)

### Gaps

- Syntax errors while loading an entry script are Julia load errors, not current workspace stage errors. DataBrowser has no public structured code-apply operation to capture them as an IDE problem list.
- Existing error strings are insufficient for reliable error navigation; a structured error payload needs to preserve file, line, operation, data identity, and full exception details where available.
- No current API establishes conflict detection, file watching, encoding policy, per-file revision, or a project code file set. Those belong to the proposed editor/document layer.

## What should be built and accepted first?

### Takeaway

The public registration/rebuild workflow has passed a same-session experiment. Finish the real SuperGaN GUI demonstration and named-method revision checks, then add read-only text inspection, reliable project-file editing, and a public code-apply operation in small items. Do not implement an editor that silently shows stale scientific results.

### Cited Findings

- The roadmap's near-term priorities are clear public project APIs and ordinary scientific use; tests should check public behavior and record a missing interface instead of adding private workarounds. — [Roadmap direction, lines 8–12](/Users/davide/code/Julia/DataBrowser-dev/docs/roadmap.md:8); [test policy, lines 8–10](/Users/davide/code/Julia/DataBrowser-dev/test/README.md:8)
- Full verification runs through `julia --project=bench --threads=auto test/runtests.jl`; relevant workloads should be used while editing. This survey changes no package behavior, so package execution is not required to validate the notes themselves. — [Testing instructions, lines 19–32](/Users/davide/code/Julia/DataBrowser-dev/test/README.md:19); [AGENTS testing policy](/Users/davide/code/Julia/DataBrowser-dev/AGENTS.md:63)

### Inferences

| Item | Acceptance criteria | Stop/go decision |
|---|---|---|
| Public REPL experiment | One browser stays open; baseline CSV works; helper/registration edit changes visible values after the shortest public calls; runtime error can be corrected without app restart. | Stop if same-GUI refresh requires private state; add the smallest public command first. |
| Read-only text viewer | A recipe-produced text value opens without custom drawing code; copy/find/wrap/line numbers work; large files and invalid encoding fail clearly; source preview survives parser failure. | Decide whether the first slice covers item text only or also source bytes. |
| Project document layer | Explicit project files; edits/undo/save work; external dirty conflict cannot lose either version; data files stay read-only. | Decide project code root/file-set declaration. |
| Embedded editor panel | Uses documented extension hooks; file navigator and data navigator stay separate; no package-private calls. | Export/document the extension surface before integration. |
| Public Apply operation | Saved text, loaded code, and result revision are inspectable; named method edits and registration edits both work; syntax/runtime failure remains recoverable without app restart. | Start with project-scope invalidation or immediately implement per-stage invalidation? Project scope is the smaller verified path. |
| Apply on Save | Debounced saves update active views; old worker outputs cannot be labeled current after a code change; failures also invalidate after code correction. | Enable only after explicit Apply is dependable. |

The useful experiment now uses the real SuperGaN directory and one named `analyze_iv` function. Test a REPL definition first, then put only that helper in a tracked file, then change a registration in the file. These distinguish method revision from callback replacement with no launcher abstractions. Keep the same browser open and show actual screenshots after each observable result. The API researcher is running the public data checks; this note does not duplicate or fabricate its results. [Real startup script](</Users/davide/code/Julia/DataBrowser-dev/research_notes/Text viewing and source editing/supergan_live.jl>), [replacement contract](/Users/davide/code/Julia/DataBrowser-dev/lib/DataBrowserRecipes/src/registration.jl:60)

The [baseline screenshot](</Users/davide/code/Julia/DataBrowser-dev/research_notes/Text viewing and source editing/supergan-baseline.png>) shows the actual running SuperGaN app. The API researcher opened 59 CSV items and selected the real C1_2um measurement with 199 rows. A later screenshot should show the observable result after applying project code in the same session. Proposed editor behavior remains described in this note; no mockup is supplied as evidence.

### Gaps

User decisions to settle on return: whether source-byte preview is in the first slice; whether Save and Apply are separate by default; how the project declares editable code files; whether initial project-wide recomputation cost is acceptable; and whether the embedded editor must match VS Code editing features immediately. All can remain explicit choices while the no-restart public REPL experiment proceeds.
