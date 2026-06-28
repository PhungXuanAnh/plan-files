#!/bin/bash
# planning-with-files: Shared utilities for hook scripts.
# Source this file from agent-stop.sh and post-tool-use.sh; do NOT execute directly.
#
# Provides:
#   count_phases PLAN_FILE           — set globals TOTAL COMPLETE IN_PROGRESS PENDING
#   check_task_plan_format PLAN_FILE — echo issue code if plan has a structural problem

# ---------------------------------------------------------------------------
# count_phases PLAN_FILE
# Parses all ### Phase blocks in PLAN_FILE and sets five globals:
#   TOTAL        — total number of ### Phase N: headings found
#   COMPLETE     — phases with status=complete
#   IN_PROGRESS  — phases with status=in_progress
#   PENDING      — phases with status=pending
#   DEFERRED     — phases with status=deferred (reason); only counted when
#                  the parenthesised reason is non-empty. `deferred` without
#                  a valid `(reason)` is NOT counted here — check_task_plan_format
#                  will surface DEFERRED_NO_REASON for the agent-stop hook.
#
# Rules: scoped to phase blocks; at most one status credited per phase (heading
# inline marker takes precedence over body marker); HTML comments are ignored.
# ---------------------------------------------------------------------------
count_phases() {
    local _plan_file="${1:-}"
    read TOTAL COMPLETE IN_PROGRESS PENDING DEFERRED <<EOF
$(awk '
  function flush() {
    if (in_phase) {
      if      (status == "complete")    complete++
      else if (status == "in_progress") in_progress++
      else if (status == "pending")     pending++
      else if (status == "deferred")    deferred++
    }
  }
  BEGIN { total=0; complete=0; in_progress=0; pending=0; deferred=0; in_phase=0; status=""; in_comment=0 }
  /<!--/ { in_comment=1 }
  in_comment { if (/-->/) in_comment=0; next }
  /^### Phase/ {
    flush(); in_phase=1; total++; status=""
    if      ($0 ~ /\[complete\]/)    status="complete"
    else if ($0 ~ /\[in_progress\]/) status="in_progress"
    else if ($0 ~ /\[pending\]/)     status="pending"
    next
  }
  /^### / || /^## / { flush(); in_phase=0; status=""; next }
  !in_phase { next }
  status != "" { next }
  /\*\*Status:\*\*[[:space:]]*complete([^a-zA-Z_]|$)/    { status="complete";    next }
  /\*\*Status:\*\*[[:space:]]*in_progress([^a-zA-Z_]|$)/ { status="in_progress"; next }
  /\*\*Status:\*\*[[:space:]]*pending([^a-zA-Z_]|$)/     { status="pending";     next }
  # Deferred: only credit when "(reason)" with at least one non-whitespace char is present.
  # Bare "deferred" or "deferred ()" is left with status="" so format check can flag it.
  /\*\*Status:\*\*[[:space:]]*deferred[[:space:]]*\([[:space:]]*[^)[:space:]][^)]*\)/ { status="deferred"; next }
  /\[complete\]/    { status="complete";    next }
  /\[in_progress\]/ { status="in_progress"; next }
  /\[pending\]/     { status="pending";     next }
  END { flush(); printf "%d %d %d %d %d", total, complete, in_progress, pending, deferred }
' "$_plan_file" 2>/dev/null)
EOF
    : "${TOTAL:=0}" "${COMPLETE:=0}" "${IN_PROGRESS:=0}" "${PENDING:=0}" "${DEFERRED:=0}"
}

# ---------------------------------------------------------------------------
# check_task_plan_format PLAN_FILE
# Requires: count_phases already called (reads TOTAL COMPLETE IN_PROGRESS PENDING DEFERRED).
# Active only while COMPLETE=0 AND DEFERRED=0 (planning phase); silently no-ops once work begins.
# Echoes one of these issue codes to stdout, or nothing if the plan is correct:
#   NO_PHASES            — zero ### Phase N: headings detected
#   NO_STATUS_MARKERS    — headings found but zero recognized status markers
#   DEFERRED_NO_REASON   — `**Status:** deferred` line present but missing required `(reason)`
#                          (always checked, even during/after work — bare `deferred` is never valid)
#   PROFILE_MISSING      — ## Workflow Profile section absent
#   PROFILE_UNFILLED     — ## Workflow Profile present but **Profile:** still placeholder
# ---------------------------------------------------------------------------
check_task_plan_format() {
    local _plan_file="${1:-}"
    local _complete="${COMPLETE:-0}"
    local _total="${TOTAL:-0}"
    local _in_progress="${IN_PROGRESS:-0}"
    local _pending="${PENDING:-0}"
    local _deferred="${DEFERRED:-0}"

    # Bare `**Status:** deferred` (no reason / empty parens) is ALWAYS invalid,
    # regardless of how far the plan has progressed. Detect lines that start a
    # deferred marker but do NOT match the strict "deferred (non-empty reason)" form.
    if grep -Eq '\*\*Status:\*\*[[:space:]]*deferred([[:space:]]*\([[:space:]]*\)|[[:space:]]*$|[[:space:]]+[^(])' "$_plan_file" 2>/dev/null; then
        # Confirm there is a deferred line that does NOT have a valid (reason).
        # The grep above can false-positive on whitespace edge cases; double-check
        # by ensuring at least one deferred line is NOT in the valid form.
        local _bad
        _bad=$(grep -E '\*\*Status:\*\*[[:space:]]*deferred' "$_plan_file" 2>/dev/null \
            | grep -Ev '\*\*Status:\*\*[[:space:]]*deferred[[:space:]]*\([[:space:]]*[^)[:space:]][^)]*\)' \
            | head -1)
        if [ -n "$_bad" ]; then
            printf 'DEFERRED_NO_REASON'
            return
        fi
    fi

    # Once work has begun (any phase complete or deferred), skip planning-phase checks.
    if [ "$_complete" -gt 0 ] || [ "$_deferred" -gt 0 ]; then
        return 0
    fi

    if [ "$_total" -eq 0 ]; then
        printf 'NO_PHASES'
        return
    fi

    # COMPLETE=0 and DEFERRED=0 here. If IN_PROGRESS=0 and PENDING=0 too,
    # all status markers are unrecognized.
    if [ "$_in_progress" -eq 0 ] && [ "$_pending" -eq 0 ]; then
        printf 'NO_STATUS_MARKERS'
        return
    fi

    # Phase structure OK — check Workflow Profile section.
    if ! grep -qE '^## Workflow Profile[[:space:]]*$' "$_plan_file" 2>/dev/null; then
        printf 'PROFILE_MISSING'
        return
    fi

    local _profile_line
    _profile_line=$(awk '/^## Workflow Profile[[:space:]]*$/{f=1;next} f && /^## /{f=0} f && /\*\*Profile:\*\*/{print;exit}' "$_plan_file" 2>/dev/null | head -1)
    if ! printf '%s' "${_profile_line:-}" | grep -Eq '\*\*Profile:\*\*[[:space:]]*(A|B|C)[[:space:]]*$'; then
        printf 'PROFILE_UNFILLED'
        return
    fi
}

# ---------------------------------------------------------------------------
# phase_summary PLAN_FILE
# Emits one TSV line per ### Phase block:
#   <phase_num>\t<status>\t<unchecked_count>\t<first_unchecked_text>
# Where:
#   phase_num             — integer N from "### Phase N:" (or empty if unparsable)
#   status                — complete | in_progress | pending | "" (no marker)
#   unchecked_count       — count of "- [ ]" lines inside the phase block
#   first_unchecked_text  — text of first "- [ ]" line (truncated to 200 chars)
# Phase block boundaries: from the heading until the next ### or ## heading.
# HTML comments are skipped.
# ---------------------------------------------------------------------------
phase_summary() {
    local _plan_file="${1:-}"
    awk '
      function flush() {
        if (in_phase) {
          gsub(/\t/, " ", first)
          if (length(first) > 200) first = substr(first, 1, 200) "..."
          printf "%s\t%s\t%d\t%s\n", num, status, unchecked, first
        }
      }
      BEGIN { in_phase=0; in_comment=0; num=""; status=""; unchecked=0; first="" }
      /<!--/ { in_comment=1 }
      in_comment { if (/-->/) in_comment=0; next }
      /^### Phase/ {
        flush()
        in_phase=1; unchecked=0; first=""; status=""; num=""
        if (match($0, /Phase[[:space:]]+[0-9]+/)) {
          tok = substr($0, RSTART, RLENGTH)
          sub(/^Phase[[:space:]]+/, "", tok)
          num = tok
        }
        if      ($0 ~ /\[complete\]/)    status="complete"
        else if ($0 ~ /\[in_progress\]/) status="in_progress"
        else if ($0 ~ /\[pending\]/)     status="pending"
        next
      }
      /^### / || /^## / { flush(); in_phase=0; status=""; unchecked=0; first=""; num=""; next }
      !in_phase { next }
      /^- \[ \]/ {
        unchecked++
        if (first == "") { first = $0; sub(/^- \[ \] */, "", first) }
        next
      }
      status != "" { next }
      /\*\*Status:\*\*[[:space:]]*complete([^a-zA-Z_]|$)/    { status="complete";    next }
      /\*\*Status:\*\*[[:space:]]*in_progress([^a-zA-Z_]|$)/ { status="in_progress"; next }
      /\*\*Status:\*\*[[:space:]]*pending([^a-zA-Z_]|$)/     { status="pending";     next }
      /\*\*Status:\*\*[[:space:]]*deferred[[:space:]]*\([[:space:]]*[^)[:space:]][^)]*\)/ { status="deferred"; next }
      /\[complete\]/    { status="complete";    next }
      /\[in_progress\]/ { status="in_progress"; next }
      /\[pending\]/     { status="pending";     next }
      END { flush() }
    ' "$_plan_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# check_non_phase_work PLAN_FILE
# Scans every `### ` heading in the file. If a heading does NOT match
#   `^### Phase[[:space:]]+[0-9]`
# AND its body contains at least one `- [ ]` unchecked item before the next
# `### ` or `## ` heading, echo the offending heading text (sans `### `,
# truncated to 200 chars) on stdout and stop. Echoes nothing if the plan is
# clean.
#
# Purpose: catch the bypass pattern where the agent renames work blocks to
# `### Step N:` / `### Task N:` / `### Stage N:` etc. Those headings are
# invisible to count_phases (anchored on `^### Phase`), so unchecked work
# hidden under them never blocks the Stop hook. HTML comments are ignored.
# Heading-only sections (no checkboxes, e.g. `### Rollback`, `### Open
# question`) do NOT trigger — only sections with actual unchecked work.
# ---------------------------------------------------------------------------
check_non_phase_work() {
    local _plan_file="${1:-}"
    awk '
      function flush() {
        if (heading != "" && unchecked > 0 && !is_phase) {
          if (length(heading) > 200) heading = substr(heading, 1, 200) "..."
          print heading
          heading=""; unchecked=0
          exit
        }
      }
      BEGIN { heading=""; is_phase=0; unchecked=0; in_comment=0 }
      /<!--/ { in_comment=1 }
      in_comment { if (/-->/) in_comment=0; next }
      /^### / {
        flush()
        heading=$0; sub(/^### */, "", heading)
        is_phase = ($0 ~ /^### Phase[[:space:]]+[0-9]/)
        unchecked=0
        next
      }
      /^## / {
        flush()
        heading=""; is_phase=0; unchecked=0
        next
      }
      heading == "" { next }
      /^- \[ \]/ { unchecked++ }
      END { flush() }
    ' "$_plan_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# planning_file_budget_warning PLAN_DIR [LIMIT]
# Checks the active planning files and prints one compact warning if any file
# is over the line budget. This is intentionally advisory: hooks never mutate
# or truncate planning files.
# ---------------------------------------------------------------------------
planning_file_budget_warning() {
    local _plan_dir="${1:-}"
    local _limit="${2:-250}"
    local _items=""
    local _name _path _lines

    [ -z "$_plan_dir" ] && return 0

    for _name in tasks.md findings.md decisions.md; do
        _path="$_plan_dir/$_name"
        [ -f "$_path" ] || continue
        _lines=$(wc -l < "$_path" 2>/dev/null | tr -d ' ' || echo 0)
        _lines=${_lines:-0}
        if [ "$_lines" -gt "$_limit" ]; then
            if [ -n "$_items" ]; then
                _items="${_items}, ${_name}=${_lines}"
            else
                _items="${_name}=${_lines}"
            fi
        fi
    done

    if [ -n "$_items" ]; then
        printf '[planning-with-files] COMPACTION NEEDED: %s line(s) over the %s-line target. Compact before continuing: preserve current goal/phase, incomplete tasks, blockers, verification commands, recent errors, active user decisions, and source references. Summarize stale completed work and superseded history. Never raw-truncate.' "$_items" "$_limit"
    fi
}
