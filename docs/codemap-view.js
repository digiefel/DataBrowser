// Draw the code map of `window.CODEMAP`, which docs/codemap.jl writes, on the page codemap.md.
(function () {
  const info = document.getElementById("codemap-info");
  try { draw(); } catch (error) { info.textContent = "Failed to draw the code map: " + error; throw error; }

function draw() {
  const map = window.CODEMAP;
  // The extensions register themselves when they find `cytoscape`; register them again in case
  // they loaded first.
  for (const extension of [window.cytoscapeElk, window.cytoscapeExpandCollapse])
    try { if (extension) cytoscape.use(extension); } catch (_) {}
  const colors = {
    DataBrowserAPI: "#cfd8e3", DataBrowserCore: "#bcd4f0", DataBrowserCache: "#f5d6a8",
    DataBrowserRecipes: "#f5ecc0", DataBrowserGUI: "#d9c6ec", DataBrowserPlots: "#f2c6d4",
    DataBrowserSources: "#c9e4c5", DataBrowserAnnotations: "#b8e0d2", DataBrowserProfiling: "#ded7ef",
  };
  const pageOf = file => "code/" + file.replace(/\.jl$/, ".html");
  const githubOf = t => `https://github.com/digiefel/MeasurementBrowser/blob/${map.commit}/${t.file}#L${t.line}`;
  const escape = text => text.replace(/[&<>]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);

  // A box for each package, a box inside it for each file, and a node for each type.
  const elements = [];
  for (const p of new Set(map.types.map(t => t.package)))
    elements.push({ data: { id: "package:" + p, label: p, color: colors[p] || "#eceff1" }, classes: "package" });
  for (const f of new Set(map.types.map(t => t.package + "\t" + t.file))) {
    const [p, file] = f.split("\t");
    elements.push({ data: { id: "file:" + file, parent: "package:" + p, label: file.split("/src/").pop() }, classes: "file" });
  }
  for (const t of map.types)
    elements.push({ data: { id: t.id, parent: "file:" + t.file, label: t.name, type: t, color: colors[t.package] || "#eceff1" },
      classes: ["type", t.abstract ? "abstract" : "", t.exported ? "exported" : ""].join(" ") });
  for (const e of map.edges)
    elements.push({ data: { id: e.kind + ":" + e.source + "->" + e.target, source: e.source, target: e.target }, classes: e.kind });

  const layout = {
    name: "elk", nodeDimensionsIncludeLabels: true, fit: true,
    elk: { algorithm: "layered", "elk.direction": "DOWN", "elk.hierarchyHandling": "INCLUDE_CHILDREN",
      "elk.spacing.nodeNode": 20, "elk.layered.spacing.nodeNodeBetweenLayers": 30 },
  };
  const cy = cytoscape({
    container: document.getElementById("codemap"), elements, layout, wheelSensitivity: 0.3,
    style: [
      { selector: "node", style: { label: "data(label)", "font-size": 11, "text-valign": "center", "text-halign": "center",
        "background-color": "data(color)", shape: "round-rectangle", width: "label", height: 22, padding: 6,
        "border-width": 1, "border-color": "#666", color: "#111" } },
      { selector: ".package", style: { "text-valign": "top", "font-size": 16, "font-weight": "bold", "background-opacity": 0.35 } },
      { selector: ".file", style: { "text-valign": "top", "font-size": 10, "background-color": "#ffffff", "background-opacity": 0.6,
        "border-style": "dotted", color: "#555" } },
      { selector: ".abstract", style: { "border-style": "dashed", "font-style": "italic" } },
      { selector: ".exported", style: { "border-width": 3 } },
      { selector: "edge", style: { width: 1, "curve-style": "bezier", "arrow-scale": 0.8 } },
      { selector: ".subtype", style: { "line-color": "#3f6fb0", "target-arrow-color": "#3f6fb0", "target-arrow-shape": "triangle",
        "target-arrow-fill": "hollow", width: 1.5 } },
      { selector: ".field", style: { "line-color": "#999", "target-arrow-color": "#999", "target-arrow-shape": "vee" } },
      { selector: ".faded", style: { opacity: 0.15 } },
      { selector: ":selected", style: { "border-color": "#d1495b", "border-width": 3 } },
      // The boxes that the expand-collapse extension closes.
      { selector: ".cy-expand-collapse-collapsed-node", style: { "font-size": 12, "text-valign": "center", "border-style": "solid" } },
    ],
  });
  const boxes = cy.expandCollapse({ layoutBy: layout, animate: false, undoable: false, fisheye: false, cueEnabled: false });

  // The fields and the links of a type, beside the map.
  cy.on("tap", "node.type", event => {
    const t = event.target.data("type");
    const rows = (t.fields || []).map(f => `<tr><td><code>${escape(f.name)}</code></td><td><code>${escape(f.type)}</code></td></tr>`).join("");
    info.innerHTML = `<h4><code>${escape(t.name)}</code></h4>
      <p>${t.abstract ? "abstract type" : "struct"} of ${t.package}, subtype of <code>${escape(t.supertype)}</code></p>
      <p><a href="${pageOf(t.file)}">${escape(t.file)}</a>, <a href="${githubOf(t)}">line ${t.line} on GitHub</a></p>
      ${rows ? `<table><tr><th>field</th><th>type</th></tr>${rows}</table>` : ""}`;
    // Fade what is not connected to the type.
    cy.elements().addClass("faded");
    event.target.closedNeighborhood().union(event.target.ancestors()).union(event.target.closedNeighborhood().ancestors()).removeClass("faded");
  });
  cy.on("tap", event => { if (event.target === cy) cy.elements().removeClass("faded"); });
  cy.on("dbltap", "node.package, node.file, .cy-expand-collapse-collapsed-node", event => {
    const node = event.target;
    boxes.isExpandable(node) ? boxes.expand(node) : boxes.collapse(node);
  });

  // Find a type by name.
  document.getElementById("codemap-search").addEventListener("input", event => {
    const text = event.target.value.trim().toLowerCase();
    cy.elements().removeClass("faded");
    if (!text) return;
    const found = cy.nodes(".type").filter(n => n.data("label").toLowerCase().includes(text));
    cy.elements().addClass("faded");
    found.union(found.ancestors()).removeClass("faded");
    if (found.length) cy.fit(found, 60);
  });
  document.getElementById("codemap-fit").addEventListener("click", () => cy.fit(undefined, 20));
  // "Full window" lays the map over the page; the map needs its new size before it fits.
  const frame = document.getElementById("codemap-frame"), full = document.getElementById("codemap-full");
  const setFull = on => {
    frame.classList.toggle("full", on);
    // The background of the page, whatever its theme: the first element up from the map that has one.
    let element = frame.parentElement;
    while (element && getComputedStyle(element).backgroundColor === "rgba(0, 0, 0, 0)") element = element.parentElement;
    frame.style.background = !on ? "" : element ? getComputedStyle(element).backgroundColor : "#fff";
    full.textContent = on ? "Back to the page" : "Full window";
    cy.resize(); cy.fit(undefined, 20);
  };
  full.addEventListener("click", () => setFull(!frame.classList.contains("full")));
  document.addEventListener("keydown", event => { if (event.key === "Escape") setFull(false); });
  document.getElementById("codemap-collapse").addEventListener("click", () => boxes.collapse(cy.nodes(".file")));
  document.getElementById("codemap-expand").addEventListener("click", () => boxes.expandAll());
}
})();
