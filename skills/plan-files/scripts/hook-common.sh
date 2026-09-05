#!/bin/bash
# plan-files: Canonical shared utilities for every provider hook.
# Source this file from hook-agent-stop.sh and hook-post-tool-use.sh; do NOT execute directly.
#
# Provides:
#   planning_skill_dir                — absolute installed skills/plan-files directory
#   planning_script_path NAME         — absolute path of a skill script for messages
#   planning_doc_path RELPATH         — absolute path of SKILL.md or a references/ file
#   resolve_plan_dir ROOT             — set TASK_ID PLAN_DIR PLAN_FILE from pointer
#   current_phase_pointer PLAN_FILE   — print only a valid exact `Phase N` pointer
#   planning_item_context PLAN_FILE   — print contracted item state as compact JSON
#   planning_progress_fingerprint FILE — print semantic plan progress fingerprint
#   count_phases PLAN_FILE           — set phase-count globals
#   check_task_plan_format PLAN_FILE — echo issue code if plan has a structural problem
#   task_plan_format_message CODE FILE TOTAL — render concise model-facing guidance
#   planning_file_budget_warning DIR — echo line/byte/scope warning when needed
#   planning_handoff_warning DIR     — echo warning when optional handoff.md is stale
#   planning_restore_warning DIR     — echo bounded targeted repair guidance for incomplete restore state

# ---------------------------------------------------------------------------
# resolve_plan_dir ROOT
# Sets empty globals on a missing/invalid pointer; never guesses another task.
# ---------------------------------------------------------------------------
resolve_plan_dir() {
    local _root="${1:-.}" _pointer _id
    TASK_ID="" PLAN_DIR="" PLAN_FILE=""
    _pointer="$_root/.plan-files"
    [ -e "$_root/.plan-files-skip" ] && return 0
    [ -f "$_pointer" ] || return 0
    _id=$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "$_pointer" 2>/dev/null)
    case "$_id" in
        ""|.|*/*|*..*|*" "*) return 0 ;;
    esac
    if ! printf '%s' "$_id" | grep -Eq '^[A-Za-z0-9._-]+$'; then
        return 0
    fi
    TASK_ID="$_id"
    PLAN_DIR="$_root/tmp/plan-files/$_id"
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
# planning_skill_dir
# Absolute path of the installed skills/plan-files directory, resolved through
# install symlinks from this file's own location. Messages must name paths the
# agent can act on directly; a bare script name makes it guess or search.
# ---------------------------------------------------------------------------
planning_skill_dir() {
    local _dir _candidate
    _dir=$(CDPATH= cd -P -- "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || return 1
    for _candidate in \
        "$_dir/.." \
        "$_dir/../../../../skills/plan-files" \
        "$_dir/../../../skills/plan-files"; do
        if [ -f "$_candidate/SKILL.md" ]; then
            (CDPATH= cd -P -- "$_candidate" 2>/dev/null && printf '%s' "$PWD")
            return 0
        fi
    done
    return 1
}

# planning_script_path NAME — absolute path of a skill script, or the bare name
# when the skill layout cannot be resolved, so a message never loses its verb.
planning_script_path() {
    local _dir
    _dir=$(planning_skill_dir) || { printf '%s' "${1:-}"; return 0; }
    printf '%s/scripts/%s' "$_dir" "${1:-}"
}

# planning_doc_path RELPATH — absolute path of SKILL.md or a references/ file.
planning_doc_path() {
    local _dir
    _dir=$(planning_skill_dir) || { printf '%s' "${1:-}"; return 0; }
    printf '%s/%s' "$_dir" "${1:-}"
}

planning_state_tool() {
    local _path
    _path=$(planning_script_path plan_state.py)
    [ -f "$_path" ] || return 1
    printf '%s' "$_path"
}

planning_privacy_key() {
    local _value="${1:-}" _digest=""
    if command -v sha256sum >/dev/null 2>&1; then
        _digest=$(printf '%s' "$_value" | sha256sum | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        _digest=$(printf '%s' "$_value" | shasum -a 256 | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then
        _digest=$(printf '%s' "$_value" | openssl dgst -sha256 | sed 's/^.*= //')
    fi
    [ -n "$_digest" ] && printf '%s' "$_digest" | cut -c 1-16
}


planning_item_contract_issue() {
    local _plan_file="${1:-}" _tool _output _status=0
    grep -qE '^## Active Item[[:space:]]*$' "$_plan_file" 2>/dev/null || return 0
    _tool=$(planning_state_tool 2>/dev/null) || { printf 'ITEM_STATE_TOOL_UNAVAILABLE'; return 0; }
    command -v python3 >/dev/null 2>&1 || { printf 'ITEM_STATE_TOOL_UNAVAILABLE'; return 0; }
    _output=$(python3 "$_tool" validate "$_plan_file" 2>/dev/null) || _status=$?
    if [ "$_status" -eq 2 ] && [ -n "$_output" ]; then
        printf '%s' "$_output"
    elif [ "$_status" -ne 0 ]; then
        printf 'ITEM_STATE_TOOL_UNAVAILABLE'
    fi
}

planning_item_context() {
    local _tool
    _tool=$(planning_state_tool 2>/dev/null) || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 "$_tool" context "${1:-}" 2>/dev/null
}

planning_progress_fingerprint() {
    local _tool
    _tool=$(planning_state_tool 2>/dev/null) || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 "$_tool" fingerprint "${1:-}" 2>/dev/null
}

planning_assert_finalizable() {
    local _plan_file="${1:-}" _project_root="${2:-}" _tool
    _tool=$(planning_state_tool 2>/dev/null) || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    if [ -n "$_project_root" ]; then
        python3 "$_tool" assert-finalizable "$_plan_file" --project-root "$_project_root" 2>/dev/null
    else
        python3 "$_tool" assert-finalizable "$_plan_file" 2>/dev/null
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
# Echoes every applicable issue code below, one per line (empty output if the
# plan is correct), so a single call surfaces every simultaneous violation
# instead of only the first one found across repeated block/fix/retry cycles:
#   SECTION_LAYOUT_INVALID — Current Phase / Phases section is missing, duplicated, ordered
#                            incorrectly, or contains phase headings outside ## Phases
#   CURRENT_PHASE_INVALID — pointer body is not empty or exactly one existing `Phase N`
#                           (skipped when SECTION_LAYOUT_INVALID already fired: its
#                           extraction assumes exactly one "## Current Phase"/"## Phases"
#                           section, which is exactly what's already broken then)
#   PHASE_HEADING_INVALID — a `### Phase` heading does not match `### Phase N: Title`
#   NO_PHASES            — zero ### Phase N: headings detected
#   PHASE_STATUS_INVALID — a phase has missing or duplicate recognized status markers
#   BLOCKED_NO_REASON    — `**Status:** blocked` line present but missing required `(reason)`
#   DEFERRED_NO_REASON   — `**Status:** deferred` line present but missing required `(reason)`
#                          (always checked, even during/after work — bare `deferred` is never valid)
#   PROFILE_MISSING      — ## Workflow Profile section absent
#   PROFILE_UNFILLED     — ## Workflow Profile present but **Profile:** still placeholder
# All other checks below are independent of section-layout validity (pure
# regex/awk scans that cannot crash or misfire on malformed input), so they
# always run regardless of what else was already found.
# ---------------------------------------------------------------------------
check_task_plan_format() {
    local _plan_file="${1:-}"
    local _complete="${COMPLETE:-0}"
    local _total="${TOTAL:-0}"
    local _in_progress="${IN_PROGRESS:-0}"
    local _pending="${PENDING:-0}"
    local _blocked="${BLOCKED:-0}"
    local _deferred="${DEFERRED:-0}"
    local _issues=""

    _fmt_add_issue() {
        if [ -n "$_issues" ]; then
            _issues="$_issues
$1"
        else
            _issues="$1"
        fi
    }

    local _current_count _phases_count _current_line _phases_line _inside_total
    local _section_layout_bad=0
    _current_count=$(grep -Ec '^## Current Phase[[:space:]]*$' "$_plan_file" 2>/dev/null || true)
    _phases_count=$(grep -Ec '^## Phases[[:space:]]*$' "$_plan_file" 2>/dev/null || true)
    _current_count=${_current_count:-0}
    _phases_count=${_phases_count:-0}
    if [ "$_current_count" -ne 1 ] || [ "$_phases_count" -ne 1 ]; then
        _section_layout_bad=1
    else
        _current_line=$(grep -nE '^## Current Phase[[:space:]]*$' "$_plan_file" 2>/dev/null | cut -d: -f1 | head -1)
        _phases_line=$(grep -nE '^## Phases[[:space:]]*$' "$_plan_file" 2>/dev/null | cut -d: -f1 | head -1)
        if [ "${_current_line:-0}" -ge "${_phases_line:-0}" ]; then
            _section_layout_bad=1
        fi
    fi

    if grep -E '^### Phase' "$_plan_file" 2>/dev/null \
        | grep -Ev '^### Phase[[:space:]]+[0-9]+:[[:space:]]+[^[:space:]]' \
        | grep -q .; then
        _fmt_add_issue PHASE_HEADING_INVALID
    fi

    # inside_total's "## Phases" scoping is only meaningful once sections are
    # already known singular; skip it (not a new code either way) when a
    # duplicate/misordered section was already found above.
    if [ "$_section_layout_bad" -eq 0 ]; then
        _inside_total=$(awk '
          /^## Phases[[:space:]]*$/ { in_phases=1; next }
          in_phases && /^## / { in_phases=0 }
          in_phases && /^### Phase/ { count++ }
          END { print count+0 }
        ' "$_plan_file" 2>/dev/null)
        _inside_total=${_inside_total:-0}
        if [ "$_inside_total" -ne "$_total" ]; then
            _section_layout_bad=1
        fi
    fi
    [ "$_section_layout_bad" -eq 1 ] && _fmt_add_issue SECTION_LAYOUT_INVALID

    # CURRENT_PHASE_INVALID's extraction assumes exactly one "## Current Phase"
    # section — only reliable once section layout is confirmed valid.
    if [ "$_section_layout_bad" -eq 0 ]; then
        local _current_body _current_body_lines _current_num _current_bad=0
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
            _current_bad=1
        elif [ -n "$_current_body" ]; then
            if ! printf '%s' "$_current_body" | grep -Eq '^Phase[[:space:]]+[0-9]+[[:space:]]*$'; then
                _current_bad=1
            else
                _current_num=$(printf '%s' "$_current_body" | grep -oE '[0-9]+' | head -1)
                if ! awk -v num="$_current_num" '
                  /^## Phases[[:space:]]*$/ { in_phases=1; next }
                  in_phases && /^## / { in_phases=0 }
                  in_phases && $0 ~ ("^### Phase[[:space:]]+" num ":[[:space:]]+") { found=1 }
                  END { exit(found ? 0 : 1) }
                ' "$_plan_file" 2>/dev/null; then
                    _current_bad=1
                fi
            fi
        elif [ "$_in_progress" -gt 0 ] || [ "$_complete" -gt 0 ] || [ "$_blocked" -gt 0 ] || [ "$_deferred" -gt 0 ]; then
            _current_bad=1
        fi
        [ "$_current_bad" -eq 1 ] && _fmt_add_issue CURRENT_PHASE_INVALID
    fi

    local _no_reason_bad=0
    if grep -E '\*\*Status:\*\*[[:space:]]*blocked' "$_plan_file" 2>/dev/null \
        | grep -Ev '\*\*Status:\*\*[[:space:]]*blocked[[:space:]]*\([[:space:]]*[^)[:space:]][^)]*\)' \
        | grep -q .; then
        _fmt_add_issue BLOCKED_NO_REASON
        _no_reason_bad=1
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
            _fmt_add_issue DEFERRED_NO_REASON
            _no_reason_bad=1
        fi
    fi

    if [ "$_total" -eq 0 ]; then
        _fmt_add_issue NO_PHASES
    fi

    # A bare blocked/deferred marker (no reason) is ALSO, mechanically, an
    # unrecognized status marker (0 of the required 1) — but BLOCKED_NO_REASON/
    # DEFERRED_NO_REASON above is the more specific, more actionable diagnosis
    # of that exact same root cause. Skip the generic PHASE_STATUS_INVALID
    # check when either already fired, so both codes don't report the same
    # underlying problem twice.
    local _bad_phase_status=""
    if [ "$_no_reason_bad" -eq 0 ]; then
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
    fi
    [ -n "$_bad_phase_status" ] && _fmt_add_issue PHASE_STATUS_INVALID

    local _profile_count
    _profile_count=$(grep -Ec '^## Workflow Profile[[:space:]]*$' "$_plan_file" 2>/dev/null || true)
    _profile_count=${_profile_count:-0}
    if [ "$_profile_count" -ne 1 ]; then
        _fmt_add_issue PROFILE_MISSING
    else
        local _profile_line
        _profile_line=$(awk '/^## Workflow Profile[[:space:]]*$/{f=1;next} f && /^## /{f=0} f && /\*\*Profile:\*\*/{print;exit}' "$_plan_file" 2>/dev/null | head -1)
        if ! printf '%s' "${_profile_line:-}" | grep -Eq '\*\*Profile:\*\*[[:space:]]*(A|B|C)[[:space:]]*$'; then
            _fmt_add_issue PROFILE_UNFILLED
        fi
    fi

    local _item_issue
    _item_issue=$(planning_item_contract_issue "$_plan_file")
    [ -n "$_item_issue" ] && _fmt_add_issue "$_item_issue"

    printf '%s' "$_issues"
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
            printf 'FORMAT CONTRACT VIOLATION in %s: the non-comment body of "## Current Phase" must be empty or exactly "Phase N" naming a phase that exists under "## Phases". Empty is valid ONLY while no phase has ever been complete, in_progress, blocked, or deferred (true discussion/never-started mode) — once any phase has been resolved, Current Phase must name the last resolved phase (e.g. "Phase 10"), even if that phase is complete. Set it to the correct "Phase N" instead of leaving it empty.' "$_plan_file"
            ;;
        PHASE_HEADING_INVALID)
            printf 'FORMAT CONTRACT VIOLATION in %s: every phase heading must be exactly "### Phase N: Title" with an integer, colon, and non-empty title.' "$_plan_file"
            ;;
        NO_PHASES)
            printf 'FORMAT CONTRACT VIOLATION in %s: 0 phases detected. Required heading format is exactly "### Phase N: Title" (level-3, colon, no decorations, no backticks), and each phase MUST have one recognized status. See %s > FORMAT CONTRACT. Fix the plan file headings/status markers, then continue.' "$_plan_file" "$(planning_doc_path SKILL.md)"
            ;;
        PHASE_STATUS_INVALID)
            printf 'FORMAT CONTRACT VIOLATION in %s: every phase must have exactly one recognized inline or body status.' "$_plan_file"
            ;;
        BLOCKED_NO_REASON)
            printf 'FORMAT CONTRACT VIOLATION in %s: "**Status:** blocked" requires a non-empty parenthesised reason. Use "- **Status:** blocked (external dependency)" only when a genuine external dependency prevents progress. Do not use it to silence the hook after a transient error.' "$_plan_file"
            ;;
        DEFERRED_NO_REASON)
            printf 'FORMAT CONTRACT VIOLATION in %s: "**Status:** deferred" requires a non-empty parenthesised reason. Use "- **Status:** deferred (user-directed reason)" only when the user explicitly postpones the phase. Do not use it to silence the hook after a transient error.' "$_plan_file"
            ;;
        PROFILE_MISSING)
            printf 'MISSING SECTION in %s: "## Workflow Profile" not found. This section is REQUIRED before implementation begins. It declares the agent handoff point: Profile A = PR-Handoff (stop after CI green), B = Staging-Verified (stop after staging E2E), C = Research/Document (no code/PR). Add it between "## Current Phase" and "## Phases", with "**Profile:** A" (or B or C) filled in. See %s > Workflow Profile.' "$_plan_file" "$(planning_doc_path SKILL.md)"
            ;;
        PROFILE_UNFILLED)
            printf 'UNFILLED SECTION in %s: "## Workflow Profile" found but **Profile:** is not set to A, B, or C (placeholder still present or missing). Replace the "[A | B | C]" placeholder with exactly one letter: A (PR-Handoff — stop after CI green + reviewers), B (Staging-Verified — stop after staging E2E passes), or C (Research/Document — deliverable file complete). See %s > Workflow Profile.' "$_plan_file" "$(planning_doc_path SKILL.md)"
            ;;
        ACTIVE_ITEM_SECTION_INVALID)
            printf 'OUTCOME-ITEM CONTRACT VIOLATION in %s: "## Active Item" must appear exactly once, positioned after "## Current Phase" and before "## Phases", and its non-comment body must be empty or exactly one existing ID of the form "P<phase>.<n>" or "V<phase>.<n>" (for example "P2.1"). Fix the section count/position, or replace the body with a single valid ID or leave it empty.' "$_plan_file"
            ;;
        ACTIVE_ITEM_REQUIRED)
            printf 'OUTCOME-ITEM CONTRACT VIOLATION in %s: Current Phase is in_progress and still has at least one unchecked item, but "## Active Item" is empty. Set its body to exactly one unchecked P/V ID from that phase before continuing work.' "$_plan_file"
            ;;
        ACTIVE_ITEM_INVALID)
            printf 'OUTCOME-ITEM CONTRACT VIOLATION in %s: "## Active Item" names an ID that either does not exist, is already checked, or belongs to a phase other than Current Phase — or every phase is already settled while Active Item is still non-empty. If every phase is settled, clear Active Item; otherwise set it to exactly one unchecked ID that belongs to Current Phase.' "$_plan_file"
            ;;
        ITEM_ID_INVALID)
            printf 'OUTCOME-ITEM CONTRACT VIOLATION in %s: a checkbox inside a contracted phase (one that already has "## Active Item" populated) has no "[P<phase>.<n>]" or "[V<phase>.<n>]" ID right after the checkbox mark. Add one, for example "- [ ] [P2.1] observable outcome".' "$_plan_file"
            ;;
        ITEM_ID_DUPLICATE)
            printf 'OUTCOME-ITEM CONTRACT VIOLATION in %s: the same P/V ID is used on more than one checkbox. Every ID must be unique across the entire plan file — renumber whichever checkbox duplicates an existing ID.' "$_plan_file"
            ;;
        ITEM_PHASE_MISMATCH)
            printf 'OUTCOME-ITEM CONTRACT VIOLATION in %s: a checkbox ID phase number does not match the "### Phase N" heading it is written under (for example "[P2.1]" appearing inside "### Phase 3"). Either correct the ID phase number to match its heading, or move the checkbox into the phase its ID names.' "$_plan_file"
            ;;
        ITEM_EVIDENCE_MISSING)
            printf 'OUTCOME-ITEM CONTRACT VIOLATION in %s: a checkbox inside a contracted phase has no indented "  - Evidence: ..." line directly beneath it. Add one immediately after the checkbox line, for example "  - Evidence: pending" while the item is unchecked.' "$_plan_file"
            ;;
        CHECKED_ITEM_EVIDENCE_PENDING)
            printf 'OUTCOME-ITEM CONTRACT VIOLATION in %s: an item is checked "[x]" but its Evidence line is still a placeholder (empty, "pending", "none", "n/a", "todo", or "tbd"). Replace it with concrete non-placeholder evidence — a command result, UI/API state, test result, or artifact reference — before the item may stay checked, or uncheck it if the work is not actually done.' "$_plan_file"
            ;;
        ITEM_STATE_TOOL_UNAVAILABLE)
            printf 'ENVIRONMENT ISSUE while validating outcome items in %s: python3 or %s could not be run (missing python3 on PATH, or the skill scripts directory is not intact). This is not a plan-content problem — fix the environment and retry; do not edit tasks.md to work around it.' "$_plan_file" "$(planning_script_path plan_state.py)"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# task_plan_format_messages ISSUES PLAN_FILE TOTAL
# ISSUES is check_task_plan_format's newline-separated output (one or more
# codes, or empty). Renders every code's full message so a single Stop/PostTool
# firing reports every simultaneous format violation, not only the first.
# Single-issue input renders identically to task_plan_format_message alone
# (no numbering added) so existing single-issue behavior is unchanged.
# ---------------------------------------------------------------------------
task_plan_format_messages() {
    local _issues="${1:-}" _plan_file="${2:-tasks.md}" _total="${3:-0}"
    local _count _index=0 _code _rendered=""
    [ -n "$_issues" ] || return 0
    _count=$(printf '%s\n' "$_issues" | grep -c .)
    while IFS= read -r _code; do
        [ -n "$_code" ] || continue
        _index=$((_index + 1))
        if [ "$_count" -gt 1 ]; then
            _rendered="${_rendered}(${_index}/${_count}) $(task_plan_format_message "$_code" "$_plan_file" "$_total")
"
        else
            _rendered="$(task_plan_format_message "$_code" "$_plan_file" "$_total")"
        fi
    done <<< "$_issues"
    printf '%s' "$_rendered"
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
# planning_file_budget_warning PLAN_DIR
# Warns on line, byte, or hot-plan phase-count budgets. Advisory only.
# ---------------------------------------------------------------------------
planning_file_budget_warning() {
    local _plan_dir="${1:-}" _tool
    [ -n "$_plan_dir" ] && [ -f "$_plan_dir/tasks.md" ] || return 0
    _tool=$(planning_state_tool 2>/dev/null) || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 "$_tool" budget-warning "$_plan_dir/tasks.md" 2>/dev/null || true
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
        printf '[plan-files] STALE HANDOFF: %s is newer than handoff.md. Ignore handoff.md on resume; refresh it only after final planning updates when intentionally pausing.' "$_newer"
    fi
}

# ---------------------------------------------------------------------------
# planning_restore_warning PLAN_DIR
# Emits only issue metadata and repairs; planning file bodies stay unloaded.
# ---------------------------------------------------------------------------
# planning_restore_warning PLAN_DIR [with-discussion]
# Pass "with-discussion" where an unstarted plan must be reported instead of
# treated as clean; PreTool needs it, PostTool does not.
planning_restore_warning() {
    local _plan_dir="${1:-}" _mode="${2:-}" _tool _payload
    [ -n "$_plan_dir" ] && [ -f "$_plan_dir/tasks.md" ] || return 0
    _tool=$(planning_state_tool 2>/dev/null) || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    _payload=$(python3 "$_tool" restore-check "$_plan_dir/tasks.md" 2>/dev/null) || true
    [ -n "$_payload" ] || return 0
    printf '%s' "$_payload" | PWF_STATE_TOOL="$_tool" \
        PWF_CHECKPOINT_TOOL="$(planning_script_path plan_checkpoint.py)" \
        PWF_PLAN_FILE="$_plan_dir/tasks.md" PWF_RESTORE_MODE="$_mode" \
        python3 -c 'import json,os,sys
try: p=json.load(sys.stdin)
except Exception: raise SystemExit(0)
plan=os.environ["PWF_PLAN_FILE"]
state_tool=os.environ["PWF_STATE_TOOL"]
checkpoint_tool=os.environ["PWF_CHECKPOINT_TOOL"]
if p.get("discussion_mode"):
    if os.environ.get("PWF_RESTORE_MODE") != "with-discussion": raise SystemExit(0)
    print("[plan-files] DISCUSSION ONLY. Start the user-authorized Active Item before operational work: "
          f"python3 {checkpoint_tool} --plan {plan} start <ID>.", end="")
    raise SystemExit(0)
if p.get("ok", True): raise SystemExit(0)
issues=p.get("issues", [])
parts=[]
for issue in issues[:3]:
    parts.append("{code} in {source} ## {heading}: {repair}".format(**issue))
more=len(issues)-len(parts)
if more > 0: parts.append(f"{more} more issue(s)")
print("[plan-files] RESTORE STATE ACTION REQUIRED: " + "; ".join(parts) +
      f". For the bounded complete diagnosis run: python3 {state_tool} restore-check {plan}", end="")' 2>/dev/null || true
}

# Shared Stop-invalid state, also enforced before tools and repeated after tools.
# Keep the same diagnostics for legacy and contracted plans. No session effects.
planning_integrity_warning() {
    local PLAN_FILE="$1" TOTAL COMPLETE IN_PROGRESS PENDING BLOCKED DEFERRED
    local PHASE_NUM FORMAT_ISSUES SUMMARY LIE_PHASE LIE_COUNT LIE_FIRST
    local CURRENT_NUM CURRENT_STATUS NEXT_INCOMPLETE NON_PHASE_HEADING
    local _fmt_code _num _status _unchecked _first _idx _part COMBINED
    local -a REASON_PARTS
    count_phases "$PLAN_FILE"
    PHASE_NUM=$(current_phase_pointer "$PLAN_FILE")
    REASON_PARTS=()

    FORMAT_ISSUES=$(check_task_plan_format "$PLAN_FILE")
    if [ -n "$FORMAT_ISSUES" ]; then
        while IFS= read -r _fmt_code; do
            [ -n "$_fmt_code" ] || continue
            REASON_PARTS+=("$(task_plan_format_message "$_fmt_code" "$PLAN_FILE" "$TOTAL") Fix the plan structure, then continue.")
        done <<< "$FORMAT_ISSUES"
    fi

    SUMMARY=$(phase_summary "$PLAN_FILE")
    LIE_PHASE=""
    LIE_COUNT=0
    LIE_FIRST=""
    while IFS=$'\t' read -r _num _status _unchecked _first; do
        [ -z "${_num:-}" ] && continue
        if [ "${_status:-}" = "complete" ] && [ "${_unchecked:-0}" -gt 0 ]; then
            LIE_PHASE="Phase ${_num}"
            LIE_COUNT="${_unchecked}"
            LIE_FIRST="${_first}"
            break
        fi
    done <<< "$SUMMARY"

    if [ -n "$LIE_PHASE" ]; then
        REASON_PARTS+=("STATUS LIES in ${PLAN_FILE}: ${LIE_PHASE} is marked '**Status:** complete' but still has ${LIE_COUNT} unchecked '- [ ]' item(s). First: ${LIE_FIRST} | Either (a) finish the items and check the boxes, or (b) demote the phase to '**Status:** in_progress' and update '## Current Phase' to ${LIE_PHASE}, or (c) split the remaining items into a new '### Phase N+1: ...' with '**Status:** pending'. Do not stop with unchecked items inside a 'complete' phase.")
    fi

    # Stale Current Phase: pointer references a phase whose status is settled
    # (complete, blocked, or deferred), AND a non-settled phase remains.
    # Only fires if the user actually filled in ## Current Phase (PHASE_NUM non-empty).
    if [ -n "${PHASE_NUM:-}" ] && [ $((COMPLETE + BLOCKED + DEFERRED)) -lt "$TOTAL" ]; then
        CURRENT_NUM=$(printf '%s' "$PHASE_NUM" | grep -oE '[0-9]+' | head -1)
        CURRENT_STATUS=""
        NEXT_INCOMPLETE=""
        while IFS=$'\t' read -r _num _status _unchecked _first; do
            [ -z "${_num:-}" ] && continue
            if [ "$_num" = "$CURRENT_NUM" ]; then
                CURRENT_STATUS="${_status:-}"
            fi
            if [ -z "$NEXT_INCOMPLETE" ] && [ "${_status:-}" != "complete" ] && [ "${_status:-}" != "blocked" ] && [ "${_status:-}" != "deferred" ]; then
                NEXT_INCOMPLETE="Phase ${_num}"
            fi
        done <<< "$SUMMARY"

        if { [ "$CURRENT_STATUS" = "complete" ] || [ "$CURRENT_STATUS" = "blocked" ] || [ "$CURRENT_STATUS" = "deferred" ]; } && [ -n "$NEXT_INCOMPLETE" ]; then
            REASON_PARTS+=("STALE '## Current Phase' in ${PLAN_FILE}: it points at ${PHASE_NUM} which is already '**Status:** ${CURRENT_STATUS}', but ${NEXT_INCOMPLETE} (and possibly later phases) are not settled. Update the '## Current Phase' section to '${NEXT_INCOMPLETE}' and set its status to 'in_progress' before continuing. The hook injects context based on Current Phase — leaving it on a settled phase makes the agent work on the wrong target.")
        fi
    fi

    # --- Non-Phase work check (delegated to common.sh:check_non_phase_work) ----
    # Catches the bypass pattern where the agent invents `### Step N:` /
    # `### Task N:` / `### Stage N:` headings to hide unchecked work from the
    # `^### Phase` scanner. Runs regardless of COMPLETE/TOTAL so it also fires
    # when Phase 0..N are all marked complete and the remaining work was renamed
    # to a non-Phase heading underneath. Heading-only sections (Rollback, Open
    # question, etc.) are not flagged — only ones containing `- [ ]` items.
    NON_PHASE_HEADING=$(check_non_phase_work "$PLAN_FILE")
    if [ -n "$NON_PHASE_HEADING" ]; then
        REASON_PARTS+=("FORMAT CONTRACT VIOLATION in ${PLAN_FILE}: heading '### ${NON_PHASE_HEADING}' contains unchecked '- [ ]' work items but is NOT a recognized phase heading. The ONLY heading form recognized as work is '### Phase N: Title' (level-3, the literal word 'Phase', a number, a colon). Rename it to a valid phase and add one recognized status. Do NOT stop until every block of unchecked work lives under a '### Phase N:' heading.")
    fi

    [ "${#REASON_PARTS[@]}" -gt 0 ] || return 0
    COMBINED=""
    _idx=0
    for _part in "${REASON_PARTS[@]}"; do
        _idx=$((_idx + 1))
        COMBINED="${COMBINED}(${_idx}/${#REASON_PARTS[@]}) ${_part}
"
    done
    printf '[plan-files] %s' "$COMBINED"
}

# Repeated context stays bounded; full diagnosis remains available to Stop.
planning_bounded_warning() {
    local _text="$1" _limit=3000
    if [ "${#_text}" -gt "$_limit" ]; then
        printf '%s… [diagnosis shortened; read the owned tasks.md and %s for repair]' "${_text:0:$_limit}" "$(planning_doc_path references/format-contract.md)"
    else
        printf '%s' "$_text"
    fi
}
