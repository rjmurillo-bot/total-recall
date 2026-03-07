#!/usr/bin/env bash
# Total Recall AIE cron wrapper — handles Copilot token exchange
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OPENCLAW_WORKSPACE=/home/richard/repos/total-recall
source "$SCRIPT_DIR/copilot-token.sh"
exec bash "$SCRIPT_DIR/$1" "${@:2}"
