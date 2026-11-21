#!/usr/bin/env bash
# =============================================================================
# 06_verify_local.sh : post-patch validation on THIS node. Run on BOTH nodes.
#
# USAGE:
#   ./06_verify_local.sh [--dry-run] [--from-step N]
#
# Both nodes: patches in both homes, CRS, options, broker status.
# Primary only: datapatch registry and invalid objects (a mounted standby cannot be queried).
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
init_phase verify_local
set_node_identity
if ! is_dry; then require_phase_complete 1 2; fi

s3() {
  local role; role=$(local_role)
  if [[ "${role}" == "PRIMARY" ]]; then verify_registry
  else log "  standby: registry check skipped (DBA_REGISTRY_SQLPATCH is not readable on a mounted standby)"; log "  apply lag: $(dg_apply_lag)"; fi
}
s4() { chopt_reconcile; dg_config_success && pass "broker configuration SUCCESS" || fail "broker configuration is not SUCCESS"; }

plan verify_binaries "opatch lspatches on both homes (DB ids: ${DB_HOME_EXPECTED_IDS:-auto}); lsinventory"
plan verify_crs "crsctl check crs, query crs releasepatch/softwarepatch, status resource -t"
plan s3 "PRIMARY: latest sqlpatch record per patch must be SUCCESS, utlrp, invalid objects must not grow; STANDBY: skipped, apply lag shown"
plan s4 "v\$option vs CHOPT_DISABLE='${CHOPT_DISABLE}'; dgmgrl show configuration must be SUCCESS"
should_run 1 && act "1. Patches in both homes"   verify_binaries
should_run 2 && act "2. CRS and resources"       verify_crs
should_run 3 && act "3. Registry (primary only)" s3
should_run 4 && act "4. Options and broker"      s4

is_dry && exit 0
print_summary || die "Verification failed. Marker NOT written."
mark_phase_complete 4
