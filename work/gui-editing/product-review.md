# Product review

The PM reviews usability across every client and authoring level. Engineering reviewers own the
independent technical review; the PM does not substitute a personal scheduler or storage design
for the user's product choices.

The [active plan index](../../docs/plans/README.md) owns navigation and decision status. Topic
plans own decisions and open questions once. The
[archived review](../../docs/plans/archive/2026-10-21-discussion/product-review.md) preserves the
earlier discussion; do not append another decision log here.

## Audiences

| User | Needs from the shared model |
| --- | --- |
| GUI user | Explore an unfamiliar project, inspect results and make common plots without learning Julia first |
| REPL/CLI user, including an agent | Discover and drive the same work without a GUI; familiar with Julia, possibly unfamiliar with the project |
| DBRecipes user | Read common sources and produce processed items without the type API, then use the same analysis and visualization tools as everyone else; familiar with the project, possibly less familiar with Julia |
| Type API developer | Build reusable domain packages and specialized applications with native types and explicit extension contracts |
| Maintainers | Clear code, modular parts and one model that serves all these users |

## Review questions

- Can a newcomer discover available items, groups, fields, operations and results without
  reading internal records or reverse-engineering a GUI?
- Do GUI and code actions return or refer to the same native result, with the same inputs and
  revision? Can another client obtain it through the public API?
- Can the user select a group, inspect its own result, inspect inputs separately and reuse that
  result in another step? Does this compose through hierarchy?
- Can the author develop a helper on selected data, compare another approach, and promote it
  into repeatable project work without duplicating the analysis?
- Does DBRecipes read and process common sources without exposing internal carriers, storage,
  jobs or UI state? Once items are processed, can its users combine, inspect, plot and save analysis
  through exactly the same tools as type-API and domain-package users?
- Are selections independent where requested, with explicit following/targeting rather than
  hidden changes when another tab or the REPL is used?
- Does the code panel contain real editable source and preserve user text? Can common GUI actions
  produce that source, while inline controls change only literal values?
- Does the workflow work for images, heatmaps, scattered/interpolated data and other results as
  well as curves? Does it reuse processing outside the plot builder?
- Can a user tell running work, last completed results, missing inputs and failures apart?
  Do live edits update affected work without repeating acquisition or unrelated effects?

## How to record a finding

State the user's concrete action, expected result, observed/proposed behavior and its consequence
for that workflow. Label implementation evidence separately from accepted target behavior and
unapproved proposals. Put the finding or remaining question in its owning plan; discuss through
[the curation note](../doc-curation.md) while coordinating this edit.

Ask Davide about meaningful product choices with concrete alternatives and consequences. Do not
ask him to approve unexplained terms, implementation details or decisions he already made.
