#!/usr/bin/env bash
# =============================================================================
# 05_switchback.sh : optional. Restore the original roles after 04_datapatch_primary.sh.
# Run it on the node that is the primary now (the original standby).
#
# USAGE:
#   ./05_switchback.sh [--dry-run] [--yes]
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(hostname -s)" != "$(source "${SCRIPT_DIR}/patch.conf"; echo "${STANDBY_HOST}")" ]]; then
  echo "Nothing to do on $(hostname -s): the switchback is run on the original standby host (the current primary)."
  exit 0
fi
exec bash "${SCRIPT_DIR}/03_switchover.sh" "$@"
