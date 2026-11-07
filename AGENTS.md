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
make each one the subject of the sentences about it:

- "List the items that the tree shows" → "Build the tree"
- "The lines of the tree could not be made" → "Failed to build the tree"

Before you send a text, read each sentence once, as its reader would. The rules below describe the
faults most likely to trip a reader, each with sentences that show the fault and its fix. Still, no
rule justifies a sentence that sounds unnatural.

1. **Explain each term where it first appears.** Say what it is in the same sentence, in familiar
   words, and with a comparison when one fits; a concrete noun is always clearer than a vague
   description. When a text needs several new terms, define each one in the example that first
   uses it. Also, mark a term in italics where you define it, and nowhere else.
   - "Each user has an inbox. The inbox stores messages." → "Each user has an *inbox*, which holds
     the messages sent to them."
   - "A place that keeps values" → "A table with one row for each value, as in a spreadsheet"
   - "`Row(3)`" with no explanation → "`Row(3)` is the third row of the table"
   - a list of definitions at the top of the page → "When you save a file, the server adds a
     *job*, a unit of work that waits in its queue."
2. **Stay on the topic: what it is and what it does.** Sentences about the text, its words or its
   readers give the reader nothing. Likewise, denying something the reader had no reason to expect
   makes them wonder whether it is true; the pattern "X, not Y" and claims about what other code
   does not do have the same effect. Finally, a list given to support a claim has to show it.
   - "The terms below mean the following:" → define each term where it first appears instead
   - "There are no special users." → "Every user has the same rights."
   - "The cache keeps results, not inputs." → "The cache keeps the result of each computation."
   - "Users are all the same: an admin, a bot and a guest" → "Every user has the same rights,
     whether an admin, a bot or a guest."
3. **Make the actor the subject of a main clause.** A long opening phrase keeps the reader waiting
   for the actor, and so do two nouns before their verb.
   - "For an order that has shipped and a cancellation from the customer, the store refunds it" →
     "When a customer cancels an order that has already shipped, the store refunds it."
   - "the items that the tree shows" → "the items shown by the tree", or "the tree shows the
     items"
   - "the files that the user opens" → "the files opened by the user"
4. **Let each word mean one thing at first reading.** Use one term for each thing, the same one the
   code uses. Beyond that, three things make a word ambiguous: a noun used as a verb, above all
   when the text also uses it as a thing; a short word before the context makes it clear; and a
   pronoun that could refer to more than one noun.
   - "the log records each request" → "the log saves each request"; other verbs that read only
     one way are *refers to*, *shows*, *follows* and *calls*
   - "a call", before the text has mentioned a function → "a function call"
   - "When the server sends the client a reply, it closes the connection" → "After sending the
     client a reply, the server closes the connection."
   - "the rows of the tree", then "the lines of the tree" for the same thing → "the items of the
     tree" both times
5. **Connect each sentence to the one before.** Readers expect a sentence to follow from the
   previous one, and several short sentences with nothing to link them leave the reader to guess
   how they relate. When a sentence starts a new point, say so with a word such as *also*,
   *besides* or *however*, or begin a new paragraph.
   - "Use concrete nouns. Italics mark jargon where it is defined." → "Use concrete nouns. Also,
     mark a term in italics where you define it."
   - "Drafts are saved every minute. Attachments have a size limit." → "Drafts are saved every
     minute. There is also a size limit for attachments."

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
