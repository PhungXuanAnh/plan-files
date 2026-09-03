#!/usr/bin/env bash
# Backward-compatible shell API; policy lives in the canonical shared shell core.
_pwf_dir=$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
while [ "$_pwf_dir" != / ] && [ ! -f "$_pwf_dir/skills/plan-files/scripts/hook-common.sh" ]; do _pwf_dir=$(dirname "$_pwf_dir"); done
# shellcheck source=/dev/null
source "$_pwf_dir/skills/plan-files/scripts/hook-common.sh"
unset _pwf_dir
