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
5. **Apply** what holds. A finding that asks for a rename of an API name, or shows that the docs
   and the code disagree on what the program should do, goes to Davide as a question instead.
6. **Rebuild** the site with `julia --project=docs docs/make.jl`, check that the pages give no
   warnings, and commit. Comments and docstrings only: no test run.

Keep the reports and rendered pages of each round in the scratchpad, one folder per round. Each
round raises new questions, so stop when the findings become small, and report the verdicts.

## Writing rules

- **Say what the thing is**, in familiar terms: "The catalog is a table with one row for each
  computation"; "`Row(3)` is the third row, as in a spreadsheet". Then ordinary words need no
  definition.
- **Attach a definition with a relative clause**, not with a new sentence that starts with the
  same noun: "Each workspace has one *catalog*, which holds…, decides…".
- **Put the event in a main clause, with its actor as the subject**: "When a plot window draws a
  fit of the item `a/1`, which comes from the source item `a.csv`, the catalog has three rows".
  No long opening phrase of noun phrases before the main clause.
- **No meta-language**: no sentence about the words, the page or the reader ("The words that
  follow…", "the rest of the page…"). Describe the thing.
- **No noun used as a verb**, above all a word that the page uses as a thing ("the cache records"
  where a record is a thing; "names", "lists", "walks", "forwards", "answers"). Use a plain verb:
  saves, refers to, shows, follows, calls.
- **No pink elephants**: never deny what the reader had no reason to expect ("There are no kinds of
  rows", "X is not a state"). State what is.
- **No list that does not show its claim.**
- **Full terms where the context is not there yet**: "a function call", not "a call".
- **Italics only for jargon where it is defined**, never for an ordinary word.
- **No pronoun with an unclear referent.**
- **No glossary out of context**: define each word in the example, where it first happens.
- The names of a page are its vocabulary: one term for one thing, as the code names it.

When Davide corrects one sentence, find the general mistake behind it, fix it on every page, and add
the rule here and to `instructions.md`, with an invented example: the reviewer must never see a
sentence from an earlier version of a page.

## Files

- `render.jl`: renders pages as `docs/make.jl` does.
- `review.sh`: runs one fresh reviewer on one page.
- `instructions.md`: what the reviewer is told: who it is, the steps, the sentence patterns, and
  the report.
- `prose_checks.py`: candidate lists of nouns used as verbs and of restarted sentences, in the
  prose of Julia files. Read each hit; many are fine.
- `rewrap.py FILE LINE...`: rewraps the comment or docstring paragraph at each line to 100
  columns, with code spans kept whole.
