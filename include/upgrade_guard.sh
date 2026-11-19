#!/usr/bin/env bash

Run_Upgrade_Guarded()
(
    set -Ee -o pipefail
    local Upgrade_Function=$1
    local Rollback_Function=$2
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'Status=$?; trap - EXIT INT TERM; set +e; if [ "$Status" -ne 0 ]; then "$Rollback_Function"; fi; TempMycnf_Clean; exit "$Status"' EXIT
    "$Upgrade_Function"
)
