# Code map

The code map shows the types of every package, made from the code at each build of these pages. A
box holds a package, and the boxes inside it hold its files. A blue arrow with a hollow head goes
from a type to its supertype, and a gray arrow from a type to the type of one of its fields. A thick
border marks an exported type, and a dashed border an abstract type.

Scroll to zoom and drag to move. Click a type to see its fields and the links to its code, and
double-click a box to close or open it.

```@raw html
<div id="codemap-tools">
  <input id="codemap-search" type="search" placeholder="Find a type" />
  <button id="codemap-fit">Fit</button>
  <button id="codemap-collapse">Close the files</button>
  <button id="codemap-expand">Open all</button>
</div>
<div id="codemap-body">
  <div id="codemap"></div>
  <div id="codemap-info">Click a type.</div>
</div>
<style>
  #codemap-tools { display: flex; gap: 0.5em; margin-bottom: 0.5em; flex-wrap: wrap; }
  #codemap-tools input { flex: 1; min-width: 10em; padding: 0.2em 0.4em; }
  #codemap-body { display: flex; gap: 0.5em; height: 80vh; }
  #codemap { flex: 1; border: 1px solid #ccc; border-radius: 4px; background: #fafafa; }
  #codemap-info { width: 22em; overflow: auto; font-size: 0.85em; }
  #codemap-info table { font-size: 0.95em; }
</style>
<!-- Documenter loads RequireJS, whose `define` would make these libraries modules of RequireJS
instead of globals: hide it while they load. -->
<script>window.codemapDefine = window.define; window.define = undefined;</script>
<script src="https://cdn.jsdelivr.net/npm/cytoscape@3.30.2/dist/cytoscape.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/elkjs@0.9.3/lib/elk.bundled.js"></script>
<script src="https://cdn.jsdelivr.net/npm/cytoscape-elk@2.2.0/dist/cytoscape-elk.js"></script>
<script src="https://cdn.jsdelivr.net/npm/cytoscape-expand-collapse@4.1.1/cytoscape-expand-collapse.js"></script>
<script>window.define = window.codemapDefine;</script>
<script src="assets/codemap.js"></script>
<script src="assets/codemap-view.js"></script>
```
