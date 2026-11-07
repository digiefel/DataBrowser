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
links to, holds a copy of these rules, so change both together.

Write the way a person explains something to a colleague. Call things by their everyday names, and
make each one the subject of the sentences about it: when the code builds a tree, say that it builds
the tree. Before you send a text, read each sentence once, as its reader would. The rules below
describe the faults most likely to trip a reader; still, they never justify a sentence that sounds
unnatural.

1. **Explain each term where it first appears.** Say what it is in the same sentence and in familiar
   words, for example with a relative clause: "Each user has an *inbox*, which holds the messages
   sent to them." The italics mark the term at its definition and nowhere else. A comparison helps
   when one fits ("a table, as in a spreadsheet"), and a concrete noun is clearer than a vague
   description such as "a place that keeps values". When a text needs several new terms, define
   each one in the example that first uses it: a glossary at the start asks the reader to learn
   words before seeing them at work.
2. **Stay on the topic: what it is and what it does.** Sentences about the text itself, its words or
   its readers ("The terms below mean the following") give the reader nothing. Likewise, denying
   something the reader had no reason to expect ("There are no special users") makes them wonder
   whether there are, and the pattern "X, not Y" has the same effect. Finally, a list offered as
   evidence has to support the claim.
3. **Make the actor the subject of a main clause.** A long opening phrase keeps the reader waiting
   for the actor: "For an order that has shipped and a cancellation from the customer, the store
   refunds it" is clearer as "When a customer cancels an order that has already shipped, the store
   refunds it." For the same reason, avoid two nouns before their verb, as in "the files that the
   user opens", and write "the files opened by the user" or "the user opens the files" instead.
4. **Let each word mean one thing at first reading.** Use one term for each thing, the same one the
   code uses. A noun used as a verb makes the reader stumble, above all when the text also uses it
   as a thing: in "the log records each request", *records* first reads as a noun, while a verb such
   as *saves* reads only one way. Similarly, a short word needs context, so write "a function call"
   until the context makes plain what "a call" is. Finally, make sure each pronoun can refer to
   only one noun.
5. **Connect each sentence to the one before.** Readers expect a sentence to follow from the
   previous one. When a sentence starts a new point instead, say so with a word such as *also*,
   *besides* or *however*, or begin a new paragraph. Several short sentences in a row, with nothing
   to link them, leave the reader to guess how they relate.

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
