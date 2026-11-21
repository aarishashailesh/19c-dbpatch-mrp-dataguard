#!/usr/bin/env bash
# =============================================================================
# 03_switchover.sh : switch roles with DG Broker (run on the CURRENT PRIMARY).
# Used once to move the primary role to the patched standby (so the old primary can be
# patched), and optionally again by 05_switchback.sh logic to restore the roles.
#
# USAGE:
#   ./03_switchover.sh [--dry-run] [--yes]      (foreground: prompts for the SYS password)
#
# Needs sys/<password>@<tns> to reach the target (the OS-authenticated dgmgrl is not enough
# for a switchover). Prerequisite: the PEER node already ran 02_apply_standby_node.sh.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/patch.conf"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib_mrp.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib_dg.sh"
# shellcheck disable=SC2034
DG_MODE=yes
# shellcheck disable=SC2034
ORIG_ARGS=("$@")
parse_args "$@"
validate_conf
init_phase switchover
set_node_identity
if ! is_dry; then require_dg_password; fi

s1() {
  require_role "PRIMARY"
  confirm "Is ${PEER_HOST} patched (02_apply_standby_node.sh finished there, redo apply running)?"
  dg_config_success || die "Broker configuration is not SUCCESS."
  local out; out=$(dgmgrl_auth "${LOCAL_TNS}" "validate database '${PEER_DBU}'" || true)
  echo "${out}" | while IFS= read -r l; do log "  ${l}"; done
  grep -q 'Ready for Switchover:  *Yes' <<< "${out}" || die "${PEER_DBU} is not ready for switchover."
}
s2() {
  local out; out=$(dgmgrl_auth "${LOCAL_TNS}" "switchover to '${PEER_DBU}'" || true)
  echo "${out}" | while IFS= read -r l; do log "  ${l}"; done
  grep -q 'Switchover succeeded' <<< "${out}" || die "Switchover did not report success. Check show configuration on both nodes."
}
s3() {
  wait_until 600 15 "local role PHYSICAL STANDBY" is_standby || true
  [[ "$(local_role)" == "PHYSICAL STANDBY" ]] || die "Local role is not PHYSICAL STANDBY after the switchover."
  dg_config_success && pass "configuration SUCCESS after the switchover" || warn "configuration is not SUCCESS yet; wait a minute and run: dgmgrl / 'show configuration'"
}

plan s1 "local role must be PRIMARY; confirm the peer is patched; dgmgrl validate database '${PEER_DBU:-peer}' must show Ready for Switchover: Yes"
plan s2 "dgmgrl sys/<password>@${LOCAL_TNS:-tns}: switchover to '${PEER_DBU:-peer}'"
plan s3 "local role becomes PHYSICAL STANDBY; configuration SUCCESS"
should_run 1 && act "1. Checks"                        s1
should_run 2 && act "2. Switchover to ${PEER_DBU:-peer}" s2
should_run 3 && act "3. Confirm roles"                 s3

is_dry && exit 0
log "=== SWITCHOVER DONE. ${PEER_HOST} is now the primary and ${THIS_HOST} is a standby (see dg_mrp_runbook.sh for the next step) ==="
