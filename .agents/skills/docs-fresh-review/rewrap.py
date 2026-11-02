# Rewrap, to 100 columns, the prose paragraph of a Julia file that contains each given line.
# Usage: rewrap.py FILE LINE... A paragraph is a run of lines with the same comment prefix ("# ",
# "    ## ", or none inside a docstring), ended by a blank line, a docstring quote or a list item.
import re, sys, textwrap
path, targets = sys.argv[1], sorted(map(int, sys.argv[2:]), reverse=True)
lines = open(path).read().split("\n")
def prefix(s):
    m = re.match(r"^(\s*##? |)", s); return m.group(1)
def is_prose(s, pre):
    body = s[len(pre):]
    return s.startswith(pre) and body.strip() != "" and not body.startswith(("|", "```", "-", "  ", '"""')) \
        and not re.match(r"\d+\. ", body) and '"""' not in s
for t in targets:
    i = t - 1; pre = prefix(lines[i])
    if not is_prose(lines[i], pre): print("skip", t); continue
    a = i
    while a > 0 and prefix(lines[a-1]) == pre and is_prose(lines[a-1], pre) and not lines[a-1].rstrip().endswith('"""'): a -= 1
    b = i
    while b + 1 < len(lines) and prefix(lines[b+1]) == pre and is_prose(lines[b+1], pre): b += 1
    text = " ".join(l[len(pre):].strip() for l in lines[a:b+1])
    # Keep each code span on one line: wrap with its spaces hidden.
    text = re.sub(r"`[^`]*`", lambda m: m.group(0).replace(" ", "\0"), text)
    wrapped = textwrap.wrap(text, 100, initial_indent=pre, subsequent_indent=pre, break_on_hyphens=False, break_long_words=False)
    lines[a:b+1] = [l.replace("\0", " ") for l in wrapped]
open(path, "w").write("\n".join(lines))
