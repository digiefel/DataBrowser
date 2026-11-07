# Guidelines

IMPORTANT ABOVE ALL ELSE: communicate following ISO 24495-1, i.e. plain language practices.
Plain language is communication that puts readers first. It considers:
— what readers want and need to know;
— readers’ level of interest, expertise and literacy skills;
— **the context in which readers will use the document**.
Plain language ensures readers can find what they need, understand it and use it. Thus, plain language focuses on how successfully readers can use the document rather than on mechanical measures such as readability formulas.
Extensive studies have shown that writing in plain language saves time or money (or both) for readers and organizations. Plain language is more effective and produces better outcomes. In addition, readers prefer plain language. For organizations, plain language is an important way to build trust with the readers. Finally, the process of translating is more efficient for plain language documents than for documents that are difficult to understand.
Plain language is not to be confused with easy language. Plain language can be used for a general audience, while easy language is used for people who have difficulties with reading comprehension. 

Do not use meta-language or "punchy" figures of speech. Do not say that you will consider the context in which readers will use the document, or "announce" your intent. Think about the intent, think about your output, but produce actual prose/code without self-commentary or meta-references.

Keep consistent vocabulary. Avoid synonims and colorful prose. Always be specific in your wording.
Avoid overusing internal jargon. Reduce cognitive load by explaining jargon when useful.

IMPORTANT: before planning multi-package changes, and whenever broad context is needed, read the north-star document: [docs/vision.md](docs/vision.md).
For the full architectural model, when needed, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
When making a change or looking to add a feature, read the roadmap: [docs/roadmap.md](docs/roadmap.md).
Testing and benchmark instructions: [test/README.md](test/README.md).

Use docstrings when useful, and ALWAYS have docstrings on public APIs. 

This is a pre-alpha with zero users: no compatibility or migration code is ever needed.
Refactors are encouraged whenever tension arises, as few models are fixed in stone.
When code and docs disagree, fix the doc in the same commit.

## Writing

These rules apply to every text: replies in chat, documentation, docstrings, comments, commit
messages and the text of the GUI. Read every sentence once, as its reader would, before sending it.
The skill `docs-fresh-review` holds the same rules: change both together.

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

## Commands

```bash
# Generate public docs
julia --project=docs docs/make.jl
```

## Architecture
Project scripts describe how to recognize files, parse them into items, and draw plots. The package  
handles directory scanning, background processing, DuckDB caching, the item tree, selection, and the  
browser UI.  
Project code should not touch cache files, background jobs, or UI state. It is user code: a black box,  
never to be thought about or optimized.

When a workspace opens, the package works through a dependency graph with multiple stages: 
read each source item, expand what it holds into data items, process each item, process each collection from its items,
then process each item again from the collections above it (member `process`).
If the user selects items that are still processing, that work gets higher priority. 
Full detail: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Planned work lives in `docs/roadmap.md`.

## Testing

Use [test/README.md](test/README.md) as the authority for package tests, individual workloads and
full verification. While editing, run only relevant tests. Before committing, run full verification
once; unchanged successful workloads are reused. Skip execution for documentation-only changes.

## Work style

Work in small reviewable items. Always clear up confusion. Do not assume. Ask the user whenever there's decisions,
proposing various options to stimulate ideas. Asking is always better than assuming.
Conversations are always preferred to long outputs. A question mark is worth 1000 words.

After a turn with changes still pending, propose a series of one or more commits with a simple title.
Remember to advise the user when a commit or more are due, or overdue.
