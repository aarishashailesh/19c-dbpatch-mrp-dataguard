#!/usr/bin/env bash
# =============================================================================
# 02_apply_standby_node.sh : apply the MRPs to the node whose database is a STANDBY.
# Run it on the standby first, and again on the original primary after the switchover.
#
# USAGE:
#   ./02_apply_standby_node.sh [--dry-run] [--from-step N] [--foreground]
#
# Steps: 1 role and broker checks      4 Grid home: opatchauto apply GI MRP
#        2 redo apply off, stop        5 wait for CRS, start listener and database
#        3 DB home: apply MRP          6 redo apply on, wait for the apply lag
# No datapatch here: SQL changes reach a physical standby through redo from the primary.
# Runs detached under systemd-run by default (survives SSH logout / TMOUT), so it uses dgmgrl OS
# authentication and asks for no password. --foreground stays attached and allows a SYS password prompt.
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
init_phase apply_standby_node
set_node_identity
detach_self "${ORIG_ARGS[@]}"
if ! is_dry; then dg_password; require_phase_complete 1; fi

s1() {
  require_role "PHYSICAL STANDBY"
  dg_config_success || die "Broker configuration is not SUCCESS. Fix it before patching."
  sql_scalar "${DB_SID}" "select open_mode from v\$database;" > "${LOG_DIR}/.standby_open_mode" || true
  log "  standby open mode: $(cat "${LOG_DIR}/.standby_open_mode")"
  log "  apply lag: $(dg_apply_lag)"
}
s2() {
  dg_run "edit database '${LOCAL_DBU}' set state='apply-off'" || die "Could not set apply-off. Run it by hand, then re-run with --from-step 2"
  stop_listeners; stop_database
}
s3() { apply_db_home; }
s4() { apply_grid_home; }
s5() {
  wait_crs
  start_listeners; start_database
  wait_until 900 10 "instance ${DB_SID} up" instance_up || die "Standby instance did not start. Check srvctl status database -d ${DB_NAME}"
}
s6() {
  dg_run "edit database '${LOCAL_DBU}' set state='apply-on'" || die "Could not set apply-on. Run it by hand: dgmgrl / \"edit database '${LOCAL_DBU}' set state='apply-on'\""
  log "  waiting up to 15 minutes for the apply lag to drain"
  wait_until 900 20 "apply lag <= ${MAX_APPLY_LAG_SECONDS:-60}s" dg_lag_ok || warn "apply lag still high; check: show database '${LOCAL_DBU}'"
  verify_binaries
  (( FAILED == 0 )) || die "Binary verification failed."
}

plan s1 "local role must be PHYSICAL STANDBY; dgmgrl show configuration must be SUCCESS; remember open mode and apply lag"
plan s2 "dgmgrl: edit database '${LOCAL_DBU:-local}' set state='apply-off'; srvctl stop listener; srvctl stop database -d ${LOCAL_DBU:-local} -o immediate"
plan s3 "$( [[ "${DB_PATCH_METHOD}" == "DB_MRP" ]] && echo "opatch napply ./${DB_MRP_PATCH} -silent in ${DB_HOME} (as ${ORACLE_USER})" || echo "opatchauto apply -binary ${GI_MRP_DIR} -oh ${DB_HOME} (as ${ORACLE_USER})" )"
plan s4 "${GRID_HOME}/OPatch/opatchauto apply ${GI_MRP_DIR} -oh ${GRID_HOME}   (as root)"
plan s5 "wait for CRS; srvctl start listener; srvctl start database -d ${LOCAL_DBU:-local} (uses the configured start option)"
plan s6 "dgmgrl: edit database set state='apply-on'; wait for apply lag; opatch lspatches check of both homes"
should_run 1 && act "1. Role and broker checks"        s1
should_run 2 && act "2. Redo apply off, stop (OUTAGE of this node)" s2
should_run 3 && act "3. DB home: apply MRP"            s3
should_run 4 && act "4. Grid home: apply GI MRP"       s4
should_run 5 && act "5. Start CRS resources"           s5
should_run 6 && act "6. Redo apply on, verify"         s6

is_dry && exit 0
mark_phase_complete 2
log "=== BINARIES PATCHED on ${THIS_HOST}. Run the next step of dg_mrp_runbook.sh ==="
