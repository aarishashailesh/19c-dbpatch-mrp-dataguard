#!/usr/bin/env bash
# =============================================================================
# 01_prep_local.sh : MRP preparation on THIS node (ONLINE). Run on BOTH nodes.
#
# USAGE:
#   ./01_prep_local.sh [--dry-run] [--from-step N] [--detach]
#
# Steps 1 to 8 are the single-node preparation (zips, space, extract, OPatch, RU level,
# conflicts, snapshots, backups). Step 9 checks the Data Guard configuration.
# The two nodes are prepared independently: each node extracts and checks its own homes.
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
init_phase prep_local
set_node_identity
detach_self "${ORIG_ARGS[@]}"
if ! is_dry; then dg_password; fi

prep_9() {
  dg_config_success && pass "broker configuration status SUCCESS" || fail "broker configuration is not SUCCESS"
  local role; role=$(local_role); log "  local role: ${role}"
  if [[ "${role}" == "PRIMARY" ]]; then
    local out; out=$(dg_run "validate database '${PEER_DBU}'" 2>&1 || true)
    grep -q 'Ready for Switchover:  *Yes' <<< "${out}" && pass "${PEER_DBU} is ready for switchover" \
      || warn "validate database does not show 'Ready for Switchover: Yes' for ${PEER_DBU} (needed for step 3)"
  else
    log "  apply lag: $(dg_apply_lag)"
  fi
  (( FAILED == 0 )) || die "Data Guard checks failed."
}

plan prep_9 "dgmgrl show configuration must be SUCCESS; on the primary: validate database '${PEER_DBU:-peer}' for switchover readiness"
plan prep_1 "check ${GI_MRP_ZIP}, ${DB_MRP_ZIP} in ${PATCH_LOC}; OPatch present in both homes
grid and oracle can read the scripts and staging directory
crsctl check crs (CRS online); srvctl config/status database; instance status OPEN"
plan prep_2 "free space: ${PATCH_LOC} >= ${MIN_FREE_GB_STAGING} GB, each home file system >= ${MIN_FREE_GB_HOMES} GB,
${BACKUP_DIR} >= 60% of the two home sizes (BACKUP_HOMES=${BACKUP_HOMES})"
plan prep_3 "unzip ${GI_MRP_ZIP} and ${DB_MRP_ZIP} into ${PATCH_LOC}; chown root:${INSTALL_GROUP}, chmod a+rX"
plan prep_4 "opatch version in both homes; minimum ${MIN_OPATCH_VERSION}; UPDATE_OPATCH=${UPDATE_OPATCH}
(update = move OPatch to OPatch.pre_*, unzip ${OPATCH_ZIP} as the home owner)"
plan prep_5 "opatch lspatches must match RU level '${BASE_RU_REGEX}' in both homes (ALLOW_RU_MISMATCH=${ALLOW_RU_MISMATCH})
opatch lsinventory -detail -oh for both homes"
plan prep_6 "${GRID_HOME}/OPatch/opatchauto apply ${GI_MRP_DIR} -analyze -oh ${GRID_HOME}   (as root)
DB home (${DB_PATCH_METHOD}): opatch prereq CheckConflictAgainstOHWithDetail -ph ./${DB_MRP_PATCH}   (as ${ORACLE_USER})"
plan prep_7 "save opatch lspatches of both homes and the invalid object count to ${LOG_DIR}"
plan prep_8 "tar.gz of ${GRID_HOME}, ${DB_HOME}, oraInventory, oratab, olr.loc into ${BACKUP_DIR}/${MRP_LABEL}"
should_run 1 && act "1. Pre-flight"                            prep_1
should_run 2 && act "2. Disk space"                            prep_2
should_run 3 && act "3. Extract MRP zips"                      prep_3
should_run 4 && act "4. OPatch version"                        prep_4
should_run 5 && act "5. RU level and inventory"                prep_5
should_run 6 && act "6. Conflict analysis"                     prep_6
should_run 7 && act "7. Pre-patch snapshots"                   prep_7
should_run 8 && act "8. Backups"                               prep_8
should_run 9 && act "9. Data Guard health"                     prep_9

is_dry && exit 0
print_summary
mark_phase_complete 1
log "=== PREP COMPLETE on ${THIS_HOST}. Next: see dg_mrp_runbook.sh ==="
