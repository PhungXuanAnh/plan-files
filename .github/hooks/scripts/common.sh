#!/bin/bash
# planning-with-files: Shared utilities for hook scripts.
# Source this file from agent-stop.sh and post-tool-use.sh; do NOT execute directly.
#
# Provides:
#   resolve_plan_dir ROOT             — set TASK_ID PLAN_DIR PLAN_FILE from pointer
#   current_phase_pointer PLAN_FILE   — print only a valid exact `Phase N` pointer
#   count_phases PLAN_FILE           — set phase-count globals
#   check_task_plan_format PLAN_FILE — echo issue code if plan has a structural problem
#   task_plan_format_message CODE FILE TOTAL — render concise model-facing guidance
#   planning_file_budget_warning DIR — echo line/byte/scope warning when needed
#   planning_handoff_warning DIR     — echo warning when optional handoff.md is stale

# ---------------------------------------------------------------------------
# resolve_plan_dir ROOT
# Sets empty globals on a missing/invalid pointer; never guesses another task.
# ---------------------------------------------------------------------------
resolve_plan_dir() {
    local _root="${1:-.}" _pointer _id
    TASK_ID="" PLAN_DIR="" PLAN_FILE=""
    _pointer="$_root/.plan-with-files"
    [ -e "$_root/.plan-with-files-skip" ] && return 0
    [ -f "$_pointer" ] || return 0
    _id=$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "$_pointer" 2>/dev/null)
    case "$_id" in
        ""|.|*/*|*..*|*" "*) return 0 ;;
    esac
    if ! printf '%s' "$_id" | grep -Eq '^[A-Za-z0-9._-]+$'; then
        return 0
    fi
    TASK_ID="$_id"
    PLAN_DIR="$_root/tmp/plan-with-files/$_id"
    PLAN_FILE="$PLAN_DIR/tasks.md"
}

current_phase_pointer() {
    local _plan_file="${1:-}" _body
    _body=$(awk '
      /^## Current Phase[[:space:]]*$/ { capture=1; next }
      capture && /^## / { exit }
      !capture { next }
      /<!--/ { in_comment=1 }
      !in_comment && /[^[:space:]]/ { print }
      in_comment && /-->/ { in_comment=0 }
    ' "$_plan_file" 2>/dev/null)
    if [ "$(printf '%s\n' "$_body" | awk 'NF { count++ } END { print count+0 }')" -eq 1 ] \
        && printf '%s' "$_body" | grep -Eq '^Phase[[:space:]]+[0-9]+[[:space:]]*$'; then
        printf '%s' "$_body"
    fi
}

# ---------------------------------------------------------------------------
# count_phases PLAN_FILE
# Parses all ### Phase blocks in PLAN_FILE and sets six globals:
#   TOTAL        — total number of ### Phase N: headings found
#   COMPLETE     — phases with status=complete
#   IN_PROGRESS  — phases with status=in_progress
#   PENDING      — phases with status=pending
#   BLOCKED      — phases with status=blocked (reason); only counted when
#                  the parenthesised reason is non-empty
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
    read TOTAL COMPLETE IN_PROGRESS PENDING BLOCKED DEFERRED <<EOF
$(awk '
  function flush() {
    if (in_phase) {
      if      (status == "complete")    complete++
      else if (status == "in_progress") in_progress++
      else if (status == "pending")     pending++
      else if (status == "blocked")     blocked++
      else if (status == "deferred")    deferred++
    }
  }
  BEGIN { total=0; complete=0; in_progress=0; pending=0; blocked=0; deferred=0; in_phase=0; status=""; in_comment=0 }
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
  /\*\*Status:\*\*[[:space:]]*blocked[[:space:]]*\([[:space:]]*[^)[:space:]][^)]*\)/ { status="blocked"; next }
  # Deferred: only credit when "(reason)" with at least one non-whitespace char is present.
  # Bare "deferred" or "deferred ()" is left with status="" so format check can flag it.
  /\*\*Status:\*\*[[:space:]]*deferred[[:space:]]*\([[:space:]]*[^)[:space:]][^)]*\)/ { status="deferred"; next }
  /\[complete\]/    { status="complete";    next }
  /\[in_progress\]/ { status="in_progress"; next }
  /\[pending\]/     { status="pending";     next }
  END { flush(); printf "%d %d %d %d %d %d", total, complete, in_progress, pending, blocked, deferred }
' "$_plan_file" 2>/dev/null)
EOF
    : "${TOTAL:=0}" "${COMPLETE:=0}" "${IN_PROGRESS:=0}" "${PENDING:=0}" "${BLOCKED:=0}" "${DEFERRED:=0}"
}

# ---------------------------------------------------------------------------
# check_task_plan_format PLAN_FILE
# Requires: count_phases already called (reads all phase-count globals).
# Structural and profile checks always run.
# Echoes one of these issue codes to stdout, or nothing if the plan is correct:
#   SECTION_LAYOUT_INVALID — Current Phase / Phases section is missing, duplicated, ordered
#                            incorrectly, or contains phase headings outside ## Phases
#   CURRENT_PHASE_INVALID — pointer body is not empty or exactly one existing `Phase N`
#   PHASE_HEADING_INVALID — a `### Phase` heading does not match `### Phase N: Title`
#   NO_PHASES            — zero ### Phase N: headings detected
#   PHASE_STATUS_INVALID — a phase has missing or duplicate recognized status markers
#   BLOCKED_NO_REASON    — `**Status:** blocked` line present but missing required `(reason)`
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
    local _blocked="${BLOCKED:-0}"
    local _deferred="${DEFERRED:-0}"

    local _current_count _phases_count _current_line _phases_line _inside_total
    _current_count=$(grep -Ec '^## Current Phase[[:space:]]*$' "$_plan_file" 2>/dev/null || true)
    _phases_count=$(grep -Ec '^## Phases[[:space:]]*$' "$_plan_file" 2>/dev/null || true)
    _current_count=${_current_count:-0}
    _phases_count=${_phases_count:-0}
    if [ "$_current_count" -ne 1 ] || [ "$_phases_count" -ne 1 ]; then
        printf 'SECTION_LAYOUT_INVALID'
        return
    fi

    _current_line=$(grep -nE '^## Current Phase[[:space:]]*$' "$_plan_file" 2>/dev/null | cut -d: -f1 | head -1)
    _phases_line=$(grep -nE '^## Phases[[:space:]]*$' "$_plan_file" 2>/dev/null | cut -d: -f1 | head -1)
    if [ "${_current_line:-0}" -ge "${_phases_line:-0}" ]; then
        printf 'SECTION_LAYOUT_INVALID'
        return
    fi

    if grep -E '^### Phase' "$_plan_file" 2>/dev/null \
        | grep -Ev '^### Phase[[:space:]]+[0-9]+:[[:space:]]+[^[:space:]]' \
        | grep -q .; then
        printf 'PHASE_HEADING_INVALID'
        return
    fi

    _inside_total=$(awk '
      /^## Phases[[:space:]]*$/ { in_phases=1; next }
      in_phases && /^## / { in_phases=0 }
      in_phases && /^### Phase/ { count++ }
      END { print count+0 }
    ' "$_plan_file" 2>/dev/null)
    _inside_total=${_inside_total:-0}
    if [ "$_inside_total" -ne "$_total" ]; then
        printf 'SECTION_LAYOUT_INVALID'
        return
    fi

    local _current_body _current_body_lines _current_num
    _current_body=$(awk '
      /^## Current Phase[[:space:]]*$/ { capture=1; next }
      capture && /^## / { exit }
      !capture { next }
      /<!--/ { in_comment=1 }
      !in_comment && /[^[:space:]]/ { print }
      in_comment && /-->/ { in_comment=0 }
    ' "$_plan_file" 2>/dev/null)
    _current_body_lines=$(printf '%s\n' "$_current_body" | awk 'NF { count++ } END { print count+0 }')
    if [ "$_current_body_lines" -gt 1 ]; then
        printf 'CURRENT_PHASE_INVALID'
        return
    fi
    if [ -n "$_current_body" ]; then
        if ! printf '%s' "$_current_body" | grep -Eq '^Phase[[:space:]]+[0-9]+[[:space:]]*$'; then
            printf 'CURRENT_PHASE_INVALID'
            return
        fi
        _current_num=$(printf '%s' "$_current_body" | grep -oE '[0-9]+' | head -1)
        if ! awk -v num="$_current_num" '
          /^## Phases[[:space:]]*$/ { in_phases=1; next }
          in_phases && /^## / { in_phases=0 }
          in_phases && $0 ~ ("^### Phase[[:space:]]+" num ":[[:space:]]+") { found=1 }
          END { exit(found ? 0 : 1) }
        ' "$_plan_file" 2>/dev/null; then
            printf 'CURRENT_PHASE_INVALID'
            return
        fi
    elif [ "$_in_progress" -gt 0 ] || [ "$_complete" -gt 0 ] || [ "$_blocked" -gt 0 ] || [ "$_deferred" -gt 0 ]; then
        printf 'CURRENT_PHASE_INVALID'
        return
    fi

    if grep -E '\*\*Status:\*\*[[:space:]]*blocked' "$_plan_file" 2>/dev/null \
        | grep -Ev '\*\*Status:\*\*[[:space:]]*blocked[[:space:]]*\([[:space:]]*[^)[:space:]][^)]*\)' \
        | grep -q .; then
        printf 'BLOCKED_NO_REASON'
        return
    fi

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

    if [ "$_total" -eq 0 ]; then
        printf 'NO_PHASES'
        return
    fi

    local _bad_phase_status
    _bad_phase_status=$(awk '
      function flush() {
        if (in_phase && markers != 1 && bad == "") bad=1
      }
      BEGIN { in_phase=0; markers=0; in_comment=0; bad="" }
      /<!--/ { in_comment=1 }
      in_comment { if (/-->/) in_comment=0; next }
      /^### Phase[[:space:]]+[0-9]+:[[:space:]]+/ {
        flush(); in_phase=1; markers=0
        line=$0
        markers += gsub(/\[(complete|in_progress|pending)\]/, "", line)
        next
      }
      /^### / || /^## / { flush(); in_phase=0; markers=0; next }
      !in_phase { next }
      /^[[:space:]]*-[[:space:]]+\*\*Status:\*\*[[:space:]]*(complete|in_progress|pending)[[:space:]]*$/ { markers++; next }
      /^[[:space:]]*-[[:space:]]+\*\*Status:\*\*[[:space:]]*blocked[[:space:]]*\([[:space:]]*[^)[:space:]][^)]*\)[[:space:]]*$/ { markers++; next }
      /^[[:space:]]*-[[:space:]]+\*\*Status:\*\*[[:space:]]*deferred[[:space:]]*\([[:space:]]*[^)[:space:]][^)]*\)[[:space:]]*$/ { markers++; next }
      END { flush(); if (bad != "") print bad }
    ' "$_plan_file" 2>/dev/null)
    if [ -n "$_bad_phase_status" ]; then
        printf 'PHASE_STATUS_INVALID'
        return
    fi

    local _profile_count
    _profile_count=$(grep -Ec '^## Workflow Profile[[:space:]]*$' "$_plan_file" 2>/dev/null || true)
    _profile_count=${_profile_count:-0}
    if [ "$_profile_count" -ne 1 ]; then
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
# task_plan_format_message ISSUE PLAN_FILE TOTAL
# Keep one model-facing explanation per format rule so hook adapters stay aligned.
# ---------------------------------------------------------------------------
task_plan_format_message() {
    local _issue="${1:-}" _plan_file="${2:-tasks.md}" _total="${3:-0}"
    case "$_issue" in
        SECTION_LAYOUT_INVALID)
            printf 'FORMAT CONTRACT VIOLATION in %s: include exactly one "## Current Phase" followed later by exactly one "## Phases", and keep every "### Phase N: Title" heading inside the Phases section.' "$_plan_file"
            ;;
        CURRENT_PHASE_INVALID)
            printf 'FORMAT CONTRACT VIOLATION in %s: the non-comment body of "## Current Phase" must be empty or exactly "Phase N", and that phase must exist under "## Phases".' "$_plan_file"
            ;;
        PHASE_HEADING_INVALID)
            printf 'FORMAT CONTRACT VIOLATION in %s: every phase heading must be exactly "### Phase N: Title" with an integer, colon, and non-empty title.' "$_plan_file"
            ;;
        NO_PHASES)
            printf 'FORMAT CONTRACT VIOLATION in %s: no valid "### Phase N: Title" headings were found under "## Phases".' "$_plan_file"
            ;;
        PHASE_STATUS_INVALID)
            printf 'FORMAT CONTRACT VIOLATION in %s: every phase must have exactly one recognized inline or body status.' "$_plan_file"
            ;;
        BLOCKED_NO_REASON)
            printf 'FORMAT CONTRACT VIOLATION in %s: blocked requires a non-empty parenthesized reason naming a genuine external dependency.' "$_plan_file"
            ;;
        DEFERRED_NO_REASON)
            printf 'FORMAT CONTRACT VIOLATION in %s: deferred requires a non-empty parenthesized reason and is allowed only when the user explicitly postpones the phase.' "$_plan_file"
            ;;
        PROFILE_MISSING)
            printf 'FORMAT CONTRACT VIOLATION in %s: add "## Workflow Profile" before "## Phases" and set "**Profile:** A", B, or C before implementation.' "$_plan_file"
            ;;
        PROFILE_UNFILLED)
            printf 'FORMAT CONTRACT VIOLATION in %s: replace the Workflow Profile placeholder with exactly A, B, or C before implementation.' "$_plan_file"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# phase_summary PLAN_FILE
# Emits one TSV line per ### Phase block:
#   <phase_num>\t<status>\t<unchecked_count>\t<first_unchecked_text>
# Where:
#   phase_num             — integer N from "### Phase N:" (or empty if unparsable)
#   status                — complete | in_progress | pending | blocked | deferred | ""
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
      /\*\*Status:\*\*[[:space:]]*blocked[[:space:]]*\([[:space:]]*[^)[:space:]][^)]*\)/ { status="blocked"; next }
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
# planning_settled_integrity_issue TASKS_FILE
# Empty only when an all-settled plan is structurally and semantically clean.
# ---------------------------------------------------------------------------
planning_settled_integrity_issue() {
    local _plan_file="${1:-}" _issue _summary _num _status _unchecked _first _hidden
    [ -f "$_plan_file" ] || { printf 'PLAN_MISSING'; return 0; }

    count_phases "$_plan_file"
    _issue=$(check_task_plan_format "$_plan_file")
    if [ -n "$_issue" ]; then
        printf '%s' "$_issue"
        return 0
    fi

    _summary=$(phase_summary "$_plan_file")
    while IFS=$'\t' read -r _num _status _unchecked _first; do
        [ -z "${_num:-}" ] && continue
        if [ "${_status:-}" = "complete" ] && [ "${_unchecked:-0}" -gt 0 ]; then
            printf 'STATUS_LIES'
            return 0
        fi
    done <<< "$_summary"

    _hidden=$(check_non_phase_work "$_plan_file")
    [ -n "$_hidden" ] && printf 'NON_PHASE_WORK'
    return 0
}

# ---------------------------------------------------------------------------
# planning_file_budget_warning PLAN_DIR
# Warns on line, byte, or hot-plan phase-count budgets. Advisory only.
# ---------------------------------------------------------------------------
planning_file_budget_warning() {
    local _plan_dir="${1:-}"
    local _items=""
    local _name _path _lines _bytes _line_limit _byte_limit _phase_count _item

    [ -z "$_plan_dir" ] && return 0

    for _name in tasks.md findings.md decisions.md handoff.md; do
        _path="$_plan_dir/$_name"
        [ -f "$_path" ] || continue
        case "$_name" in
            tasks.md)    _line_limit=150; _byte_limit=12288 ;;
            findings.md) _line_limit=250; _byte_limit=32768 ;;
            decisions.md) _line_limit=150; _byte_limit=12288 ;;
            handoff.md)  _line_limit=50;  _byte_limit=6144 ;;
        esac
        _lines=$(wc -l < "$_path" 2>/dev/null | tr -d ' ' || echo 0)
        _bytes=$(wc -c < "$_path" 2>/dev/null | tr -d ' ' || echo 0)
        _lines=${_lines:-0}
        _bytes=${_bytes:-0}
        if [ "$_lines" -gt "$_line_limit" ] || [ "$_bytes" -gt "$_byte_limit" ]; then
            _item="${_name}=${_lines}/${_line_limit} lines;${_bytes}/${_byte_limit} bytes"
            if [ -n "$_items" ]; then
                _items="${_items}, ${_item}"
            else
                _items="${_item}"
            fi
        fi
    done

    if [ -f "$_plan_dir/tasks.md" ]; then
        _phase_count=$(grep -Ec '^### Phase[[:space:]]+[0-9]+:' "$_plan_dir/tasks.md" 2>/dev/null || true)
        _phase_count=${_phase_count:-0}
        if [ "$_phase_count" -gt 12 ]; then
            _item="tasks.md=${_phase_count}/12 phase entries"
            [ -n "$_items" ] && _items="${_items}, ${_item}" || _items="${_item}"
        fi
    fi

    if [ -n "$_items" ]; then
        printf '[planning-with-files] COMPACTION NEEDED (actual/target): %s. Keep hot current state; move older completed phases, completed verification, and resolved-error summaries to history.md; consolidate findings/decisions by lifecycle; overwrite handoff.md instead of appending. Split independent follow-up work into another task. Never raw-truncate.' "$_items"
    fi
}

# ---------------------------------------------------------------------------
# planning_handoff_warning PLAN_DIR
# A handoff is stale when any required planning file is newer. Optional only.
# ---------------------------------------------------------------------------
planning_handoff_warning() {
    local _plan_dir="${1:-}"
    local _handoff _name _path _newer=""
    [ -z "$_plan_dir" ] && return 0
    _handoff="$_plan_dir/handoff.md"
    [ -f "$_handoff" ] || return 0

    for _name in tasks.md findings.md decisions.md; do
        _path="$_plan_dir/$_name"
        if [ -f "$_path" ] && [ "$_path" -nt "$_handoff" ]; then
            [ -n "$_newer" ] && _newer="${_newer}, ${_name}" || _newer="${_name}"
        fi
    done

    if [ -n "$_newer" ]; then
        printf '[planning-with-files] STALE HANDOFF: %s is newer than handoff.md. Ignore handoff.md on resume; refresh it only after final planning updates when intentionally pausing.' "$_newer"
    fi
}
