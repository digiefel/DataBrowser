#!/bin/zsh
# Run one fresh reviewer on one page: a new claude process in a new empty folder outside the
# repository, with no tools, no MCP servers and no saved session. It receives one message:
# instructions.md, the docs home page, the vision, and the page. Nothing is sent to it afterwards.
# Usage: review.sh PAGE.md REPORT.md
set -e
here=${0:A:h}
docs=${here:h:h:h}/docs
page=${1:A}
report=${2:A}
room=$(mktemp -d)
cd "$room"
{
    cat "$here/instructions.md"
    echo; echo '<home_page>'; cat "$docs/index.md"; echo '</home_page>'
    echo; echo '<vision>'; cat "$docs/vision.md"; echo '</vision>'
    echo; echo '<page>'; cat "$page"; echo '</page>'
} | claude -p --tools "" --strict-mcp-config --no-session-persistence --model opus > "$report"
cd / && rm -rf "$room"
