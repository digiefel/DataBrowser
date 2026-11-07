---
name: docs-fresh-review
description: Write and review DataBrowser's code documentation pages, the pages that docs/make.jl generates with Literate.jl from Julia files, with fresh reviewer agents that see only one page, the docs home page and the vision. Use when writing or editing the prose or docstrings of such a page, when asked for a documentation review or for fresh or adversarial reviewers, and before committing documentation prose. Holds the writing rules that Davide applies sentence by sentence.
---

# Fresh reviews of the code documentation pages

`docs/make.jl` turns each Julia file of the documented folders into a page: lines that start with
`# ` become text, `# ```text` fences become diagrams, and the rest, docstrings included, becomes
`julia` code blocks. An indented comment splits a function in two on the page; write it as `## `,
which Literate shows as `# ` inside the code block.

A page is good when a typical user can read it and explain how that part of DataBrowser works.
That user has used the browser, read the home page (`docs/index.md`) and maybe the vision
(`docs/vision.md`), and nothing else. They skim: headings, diagrams, names, signatures and
docstrings carry the page, and the prose leads from one to the next.

## The loop

1. **Write** every sentence against the writing rules below, before anyone reads it.
2. **Render** the pages, with the options of `docs/make.jl` and without building the site:
   `julia --project=docs .agents/skills/docs-fresh-review/render.jl OUTDIR lib/DataBrowserCore/src/Catalogs.jl ...`
3. **Review**, one fresh reviewer per page, all at once, in the background:
   `zsh .agents/skills/docs-fresh-review/review.sh OUTDIR/Catalogs.md REPORT.md`.
   Each reviewer is a new `claude -p` process with no tools and no saved session, in an empty
   folder outside the repository. It gets `instructions.md`, the home page, the vision and the page,
   in one message. Never message a reviewer, and never give it an earlier version of the page or an
   earlier report: the next round is new processes on the new pages. It still reads the user's
   `~/.claude/CLAUDE.md`, which holds style rules only.
4. **Check** each claim of a report against the code before acting on it. Reviewers misread, and
   a page can be right where a reviewer says it contradicts itself.
5. **Apply** what holds. A finding that shows that the docs and the code disagree on what the
   program should do goes to Davide as a question instead.
6. **Rebuild** the site with `julia --project=docs docs/make.jl`, check that the pages give no
   warnings, and commit. Comments and docstrings only: no test run.

Keep the reports and rendered pages of each round in the scratchpad, one folder per round. Each
round raises new questions, so stop when the findings become small, and report the verdicts.

## Writing rules

Read every sentence as that user would: once, without the code. `AGENTS.md`, which `CLAUDE.md`
links to, holds the same rules for every text: change both together.

Write as a person explains the code to a colleague. Call things by the words people use for them,
and make the thing the subject: "build the tree", not "list the items of the tree". The rules below
catch faults; they never justify a sentence that a person would not say.

1. **Say what the thing is, where it first appears**, in familiar terms and in a relative clause
   attached to it: "Each workspace has one *catalog*, which holds the computations…"; "The catalog
   is a table with one row for each computation"; "`Row(3)` is the third row, as in a spreadsheet".
   Use concrete nouns, never "a place that keeps values". Italics mark jargon where it is defined,
   and nothing else. Define each word inside the example where it first happens, not in a glossary
   before it.
2. **Write only about the thing, and only what it is and does.** No sentence about the words, the
   text or its audience ("The words that follow…", "the rest of the page…"). No denial of what the
   reader had no reason to expect ("There are no kinds of rows", "X is not a state", "X; not Y"),
   and no claim about what other code does not do. No list that does not show its claim.
3. **Make the actor the subject of a main clause**: "When a plot window draws a fit of the item
   `a/1`, which comes from the source item `a.csv`, the catalog has three rows", not a long opening
   phrase of noun phrases before the main clause. Never two nouns before their verb, as in "the
   items that the tree shows": write "the items shown by the tree", or "the tree shows".
4. **Let each word mean one thing at first reading.** One term for one thing, as the code names it.
   No noun used as a verb, above all a word that the text uses as a thing ("the cache records"
   where a record is a thing): saves, refers to, shows, follows, calls. The full term where the
   context is not there yet: "a function call", not "a call". No pronoun with two possible
   referents.

When Davide corrects a sentence, find the general mistake and fix it on every page. Then remove the
rule that caused it, if there is one; else sharpen the rule that should have caught it, in its
wording or its example; add a rule only when none covers the mistake. Change `instructions.md` to
match, with an invented example: the reviewer must never see a sentence from an earlier version of
a page.

## Files

- `render.jl`: renders pages as `docs/make.jl` does.
- `review.sh`: runs one fresh reviewer on one page.
- `instructions.md`: what the reviewer is told: who it is, the steps, the sentence patterns, and
  the report.
- `prose_checks.py`: candidate lists of nouns used as verbs and of restarted sentences, in the
  prose of Julia files. Read each hit; many are fine.
- `rewrap.py FILE LINE...`: rewraps the comment or docstring paragraph at each line to 100
  columns, with code spans kept whole.
