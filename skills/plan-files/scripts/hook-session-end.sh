#!/usr/bin/env bash
# Session closure releases authority without completing plan items.
exec python3 "$(dirname -- "${BASH_SOURCE[0]}")/hook_lifecycle.py" end "$@"
