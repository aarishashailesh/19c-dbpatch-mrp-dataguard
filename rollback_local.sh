#!/usr/bin/env bash
# =============================================================================
# rollback_local.sh : roll the MRPs back on THIS node. Never part of a normal run.
#
# USAGE:
#   ./rollback_local.sh --yes [--dry-run] [--foreground]
#
# Order (README section 4 of both patches, standby side first):
#   1 roll back the node whose database is a STANDBY  (apply off, stop, rollback, start, apply on)
#   2 switch over (03_switchover.sh) and roll back the other node the same way
#   3 on the node that is the PRIMARY at the end: run this script there: after the binaries are
#     rolled back it runs datapatch -verbose, which rolls the SQL changes back (redo reaches the standby)
# The role is detected from the local database, so the same command works on both nodes.
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
init_phase rollback_local
set_node_identity
detach_self "${ORIG_ARGS[@]}"
if ! is_dry && [[ "${ASSUME_YES}" != "true" ]]; then die "Rollback is an outage of this node. Re-run with --yes to confirm."; fi
if ! is_dry; then dg_password; ROLE=$(local_role); [[ -n "${ROLE}" ]] || die "Local database is down; cannot detect the role."; fi
ROLE="${ROLE:-unknown}"

rb_stop() {
  log "  role: ${ROLE}"
  if [[ "${ROLE}" == "PHYSICAL STANDBY" ]]; then dg_run "edit database '${LOCAL_DBU}' set state='apply-off'" || die "Could not set apply-off"; fi
  stop_listeners; stop_database
}
rb_start() {
  start_listeners; start_database
  wait_until 900 10 "instance up" instance_up || die "Instance did not start"
  if [[ "${ROLE}" == "PHYSICAL STANDBY" ]]; then dg_run "edit database '${LOCAL_DBU}' set state='apply-on'" || die "Could not set apply-on"
  else wait_until 900 10 "database open" db_open || die "Primary did not open"; run_datapatch; fi
}

plan rb_stop "standby: dgmgrl edit database set state='apply-off'; srvctl stop listener; srvctl stop database -d ${LOCAL_DBU:-local}"
plan rollback_db_home "opatch nrollback -id <installed MRP sub-patch ids> -silent (DB_MRP) or opatchauto rollback -binary (GI_MRP)"
plan rollback_grid_home "${GRID_HOME}/OPatch/opatchauto rollback ${GI_MRP_DIR} -oh ${GRID_HOME}"
plan rb_start "srvctl start listener/database; standby: apply-on; primary: datapatch -verbose"
act "Stop (OUTAGE of this node)"  rb_stop
act "DB home rollback"            rollback_db_home
act "Grid home rollback"          rollback_grid_home
act "Wait for CRS"                wait_crs
act "Start and finish"            rb_start

is_dry && exit 0
rm -f "${STATUS_DIR}"/phase[1-6].done
log "=== ROLLBACK DONE on ${THIS_HOST}. Phase markers cleared. ==="
