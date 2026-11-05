# DataBrowser

DataBrowser is a Julia environment for scientific data. It reads data from files, databases,
instruments and other sources, processes it with your Julia code, keeps the results, and shows them
in an interactive browser.

You describe your data once, in a Julia project: how to read it, which measurements it contains and
how to process each of them. DataBrowser reads all of the data, processes what you select,
keeps the results between sessions, and updates them when the data changes.

In the browser you select measurements, compare them and show them in windows: plots, tables,
images, or displays that your project defines for its own data. From a script or the REPL you open
the same project and work with the same data and results.

## This documentation

- [Architecture](ARCHITECTURE.md) describes how the packages work together.
- [API](api.md) describes the public functions and types.
- The remaining pages show the Julia files of the repository, one file per page: its comments as
  text, and its code.
