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
messages and the text of the GUI. The skill `docs-fresh-review` holds a copy of them, so change
both together.

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
