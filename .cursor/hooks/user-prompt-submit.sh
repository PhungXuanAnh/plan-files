#!/bin/bash
# planning-with-files: User prompt submit hook for Cursor
# Injects plan context on every user message.
# Critical for session recovery after /clear — dumps actual content, not just advice.

if [ -f tasks.md ]; then
    echo "[planning-with-files] ACTIVE PLAN — current state:"
    head -50 tasks.md
    echo ""
    echo "=== current decisions ==="
    sed -n '1,80p' decisions.md 2>/dev/null
    echo ""
    echo "[planning-with-files] Read findings.md for research context as needed. Continue from the current phase."
fi
exit 0
