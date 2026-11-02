# Two checks on the prose (comments and docstrings) of Julia files:
# 1. nouns of the page used as verbs: a word that the prose uses after "the"/"a"/"its" and also as
#    a verb after a subject ("the cache records", "a step that fails names");
# 2. a sentence that starts with the noun that ended the sentence before ("... one catalog. The
#    catalog holds ..."), which a relative clause says better.
# Usage: python3 prose_checks.py FILE.jl ...   The lists are candidates: read each hit.
import re, sys
def paragraphs(path):
    para, start, in_doc = [], 0, False
    for n, line in enumerate(open(path), 1):
        s = line.strip()
        if s.startswith('"""'):
            if s.count('"""') == 1: in_doc = not in_doc
            if para: yield start, " ".join(para); para = []
            continue
        text = s.lstrip("#").strip() if (in_doc or s.startswith("#")) else None
        if text and not text.startswith(("|", "```")) and not line.startswith("#     "):
            if not para: start = n
            para.append(re.sub(r"`[^`]*`", "X", text))
        elif para:
            yield start, " ".join(para); para = []
DET = r"(?:the|a|an|its|their|each|every|one|this|no|any|own|other|same|that)"
SUBJ = r"(?:it|that|which|who|and|also|then|never|only|first|workspace|catalog|row|cache|store|job|worker|window|item|collection|project|function|code|walk|step|source|reader|input|caller|scan|tree|module|method|type|value|result|computation|part|selection|display|package|panel|warning|they|rows|jobs|workers|items|stores|methods|functions|roots)"
files = sys.argv[1:]
paras = [(f.split("/src/")[-1], n, p) for f in files for n, p in paragraphs(f)]
nouns = set()
for _, _, p in paras:
    nouns.update(w.rstrip("s") for w in re.findall(rf"\b{DET} (\w+)\b", p.lower()))
print("== nouns used as verbs")
for f, n, p in paras:
    for m in re.finditer(rf"\b{SUBJ} (\w+?)(?:es|s|ed)\b", p, re.I):
        w = m.group(1).lower()
        if w in nouns and len(w) > 2:
            i = m.start(); print(f"{w:12} {f}:{n}: …{p[max(0,i-50):i+70]}…")
print("== sentences that start with the noun that ended the sentence before")
for f, n, p in paras:
    for m in re.finditer(r"(\w+)\.\s+(?:The|This|That|Each|A|An|Its) (\w+)", p):
        if m.group(1).lower().rstrip("s") == m.group(2).lower().rstrip("s"):
            i = m.start(); print(f"{m.group(2):12} {f}:{n}: …{p[max(0,i-60):i+70]}…")
