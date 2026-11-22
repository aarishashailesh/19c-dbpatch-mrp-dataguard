#!/usr/bin/env bash
# =============================================================================
# 04_datapatch_primary.sh : datapatch on the CURRENT PRIMARY, once BOTH nodes have patched
# binaries (after 02 ran on the standby, the switchover, and 02 on the old primary).
#
# USAGE:
#   ./04_datapatch_primary.sh [--dry-run] [--from-step N] [--yes] [--foreground]
#
# Steps: 1 checks    2 disable SYS.DB_DDL_ALERT_TRG    3 datapatch -verbose    4 enable the trigger
# The SQL changes reach the standby through redo; datapatch is never run on a standby.
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
init_phase datapatch_primary
set_node_identity
detach_self "${ORIG_ARGS[@]}"
if ! is_dry; then require_phase_complete 1 2; fi

s1() {
  require_role "PRIMARY"
  db_open || die "Primary is not OPEN."
  confirm "Are BOTH nodes patched (02_apply_standby_node.sh finished on ${THIS_HOST} and ${PEER_HOST})?"
  dg_config_success || warn "Broker configuration is not SUCCESS; datapatch can still run, but fix the configuration afterwards."
}
s2() { ddl_trigger DISABLE || die "Could not disable SYS.DB_DDL_ALERT_TRG"; }
s3() { run_datapatch; }
s4() { ddl_trigger ENABLE || die "Could not enable SYS.DB_DDL_ALERT_TRG. Enable it by hand, then re-run with --from-step 4"; }

plan s1 "local role PRIMARY and OPEN; confirm both nodes are patched; broker status"
plan s2 "alter trigger SYS.DB_DDL_ALERT_TRG disable (DDL_TRIGGER_HANDLING=${DDL_TRIGGER_HANDLING})"
plan s3 "alter pluggable database all open (CDB); cd ${DB_HOME}/OPatch; ./datapatch -verbose   (as ${ORACLE_USER})"
plan s4 "alter trigger SYS.DB_DDL_ALERT_TRG enable"
should_run 1 && act "1. Checks"                         s1
should_run 2 && act "2. Disable SYS.DB_DDL_ALERT_TRG"   s2
should_run 3 && act "3. datapatch -verbose"             s3
should_run 4 && act "4. Enable SYS.DB_DDL_ALERT_TRG"    s4

is_dry && exit 0
mark_phase_complete 3
log "=== DATAPATCH DONE on ${THIS_HOST}. Next: optional 05_switchback.sh, then 06_verify_local.sh on both nodes ==="
