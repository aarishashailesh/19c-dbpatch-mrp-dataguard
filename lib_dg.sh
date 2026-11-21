#!/usr/bin/env bash
# =============================================================================
# lib_dg.sh : Data Guard additions to lib_mrp.sh (sourced after it)
#
# Every script runs on ONE node and names the script to run on the other node
# (no passwordless SSH). The SYS password is only needed for the switchover; it is prompted
# with read -s (or taken from DG_SYS_PASSWORD) and is never written to the log or put on a
# command line. Where OS authentication is enough (apply-off/on, show configuration) the
# scripts use it, so those steps can run detached under systemd-run without a password.
# =============================================================================

THIS_HOST="$(hostname -s)"

validate_dg_conf() {
  local v bad=0
  for v in PRIMARY_HOST PRIMARY_DB_UNIQUE_NAME PRIMARY_SID STANDBY_HOST STANDBY_DB_UNIQUE_NAME STANDBY_SID; do
    [[ -n "${!v:-}" ]] || { log "ERROR: ${v} is empty in patch.conf"; bad=1; }
  done
  (( bad == 0 )) || die "Data Guard settings missing in patch.conf."
}

set_node_identity() {
  validate_dg_conf
  if [[ "${THIS_HOST}" == "${PRIMARY_HOST}" ]]; then
    LOCAL_DBU="${PRIMARY_DB_UNIQUE_NAME}"; LOCAL_SID="${PRIMARY_SID}"; LOCAL_TNS="${PRIMARY_TNS:-${PRIMARY_DB_UNIQUE_NAME}}"
    PEER_HOST="${STANDBY_HOST}"; PEER_DBU="${STANDBY_DB_UNIQUE_NAME}"; PEER_TNS="${STANDBY_TNS:-${STANDBY_DB_UNIQUE_NAME}}"
  elif [[ "${THIS_HOST}" == "${STANDBY_HOST}" ]]; then
    LOCAL_DBU="${STANDBY_DB_UNIQUE_NAME}"; LOCAL_SID="${STANDBY_SID}"; LOCAL_TNS="${STANDBY_TNS:-${STANDBY_DB_UNIQUE_NAME}}"
    PEER_HOST="${PRIMARY_HOST}"; PEER_DBU="${PRIMARY_DB_UNIQUE_NAME}"; PEER_TNS="${PRIMARY_TNS:-${PRIMARY_DB_UNIQUE_NAME}}"
  elif is_dry; then
    warn "This host (${THIS_HOST}) is neither PRIMARY_HOST nor STANDBY_HOST: dry-run continues with the standby values"
    LOCAL_DBU="${STANDBY_DB_UNIQUE_NAME}"; LOCAL_SID="${STANDBY_SID}"; LOCAL_TNS="${STANDBY_TNS:-${STANDBY_DB_UNIQUE_NAME}}"
    PEER_HOST="${PRIMARY_HOST}"; PEER_DBU="${PRIMARY_DB_UNIQUE_NAME}"; PEER_TNS="${PRIMARY_TNS:-${PRIMARY_DB_UNIQUE_NAME}}"
  else
    die "This host (${THIS_HOST}) is neither PRIMARY_HOST (${PRIMARY_HOST}) nor STANDBY_HOST (${STANDBY_HOST}) in patch.conf."
  fi
  # shellcheck disable=SC2034
  DB_NAME="${LOCAL_DBU}"; DB_SID="${LOCAL_SID}"
  log "Node ${THIS_HOST}: db_unique_name ${LOCAL_DBU}, sid ${LOCAL_SID}; peer ${PEER_HOST} (${PEER_DBU})"
}

local_role() { sql_scalar "${DB_SID}" "select database_role from v\$database;" || true; }   # PRIMARY | PHYSICAL STANDBY

require_role() {   # require_role "PRIMARY" | "PHYSICAL STANDBY"
  local r; r=$(local_role)
  [[ "${r}" == "$1" ]] || die "Run this script on the node whose database role is '$1'. Local role: '${r:-unknown (database down?)}'."
  log "Local database role: ${r}"
}

dg_password() {   # prompt once if a terminal is attached; an empty answer means "OS authentication only"
  if [[ -z "${DG_SYS_PASSWORD:-}" && -t 0 ]]; then
    read -r -s -p "SYS password for DG Broker (not stored; Enter = use OS authentication only): " DG_SYS_PASSWORD; echo
    export DG_SYS_PASSWORD
  fi
  return 0
}

require_dg_password() {
  dg_password
  [[ -n "${DG_SYS_PASSWORD:-}" ]] || die "This step needs the SYS password (switchover). Run it in the foreground or export DG_SYS_PASSWORD."
}

# dgmgrl_auth <tns> <command> : connect sys/<password>@<tns>. The password is read from a 600 temp
# file by the oracle user and goes to dgmgrl on stdin, so it never appears in ps or in a log.
dgmgrl_auth() {
  local tns="$1" cmd="$2" pf cf rc=0
  pf=$(mktemp "${TMP_DIR}/dgp.XXXXXX"); cf=$(mktemp "${TMP_DIR}/dgc.XXXXXX")
  printf '%s' "${DG_SYS_PASSWORD}" > "${pf}"; printf '%s\n' "${cmd}" > "${cf}"
  chown "${ORACLE_USER}" "${pf}"; chmod 600 "${pf}"; chmod 644 "${cf}"
  run_as "${ORACLE_USER}" "$(ora_env "${DB_HOME}")${NL}{ printf 'connect sys/%s@%s\\n' \"\$(cat ${pf})\" '${tns}'; cat ${cf}; } | ${DB_HOME}/bin/dgmgrl -silent 2>&1" || rc=$?
  rm -f "${pf}" "${cf}"
  return "${rc}"
}

# OS authentication against the local instance (needs the local instance up)
dgmgrl_os() {
  local cf rc=0
  cf=$(mktemp "${TMP_DIR}/dgc.XXXXXX"); printf '%s\n' "$1" > "${cf}"; chmod 644 "${cf}"
  run_as "${ORACLE_USER}" "$(ora_env "${DB_HOME}" "${DB_SID}")${NL}${DB_HOME}/bin/dgmgrl -silent / < ${cf} 2>&1" || rc=$?
  rm -f "${cf}"
  return "${rc}"
}

primary_tns() { [[ "$(local_role)" == "PRIMARY" ]] && echo "${LOCAL_TNS}" || echo "${PEER_TNS}"; }

# dg_run <command> : OS authentication first, then sys/<password> to the current primary.
# Succeeds only when dgmgrl printed "Succeeded." (or the command is a show command with no error).
dg_run() {
  local cmd="$1" out
  out=$(dgmgrl_os "${cmd}" || true)
  if ! grep -Eq 'ORA-[0-9]+|DGM-[0-9]+' <<< "${out}"; then
    echo "${out}" | while IFS= read -r l; do log "  ${l}"; done; return 0
  fi
  if [[ -n "${DG_SYS_PASSWORD:-}" ]]; then
    out=$(dgmgrl_auth "$(primary_tns)" "${cmd}" || true)
    echo "${out}" | while IFS= read -r l; do log "  ${l}"; done
    ! grep -Eq 'ORA-[0-9]+|DGM-[0-9]+' <<< "${out}" && return 0
  else
    echo "${out}" | while IFS= read -r l; do log "  ${l}"; done
  fi
  return 1
}

dg_config_success() {
  local out; out=$(dgmgrl_os "show configuration" || true)
  echo "${out}" | while IFS= read -r l; do log "  ${l}"; done
  grep -A1 'Configuration Status:' <<< "${out}" | grep -q 'SUCCESS'
}

dg_apply_lag() { sql_scalar "${DB_SID}" "select value from v\$dataguard_stats where name='apply lag';" || true; }

dg_lag_ok() {
  local v secs; v=$(dg_apply_lag)
  [[ "${v}" =~ ^\+?([0-9]+)\ ([0-9]{2}):([0-9]{2}):([0-9]{2}) ]] || return 1
  secs=$(( 10#${BASH_REMATCH[1]} * 86400 + 10#${BASH_REMATCH[2]} * 3600 + 10#${BASH_REMATCH[3]} * 60 + 10#${BASH_REMATCH[4]} ))
  (( secs <= ${MAX_APPLY_LAG_SECONDS:-60} ))
}

is_standby() { [[ "$(local_role)" == "PHYSICAL STANDBY" ]]; }

instance_up() { local st; st=$(sql_scalar "${DB_SID}" "select status from v\$instance;" || true); [[ "${st}" == "MOUNTED" || "${st}" == "OPEN" ]]; }

confirm() {   # confirm "<question>"   (--yes skips the prompt)
  [[ "${ASSUME_YES}" == "true" ]] && return 0
  [[ -t 0 ]] || die "Confirmation needed but no terminal attached. Re-run with --yes once you have checked: $1"
  local a; read -r -p "$1 [type YES to continue]: " a
  [[ "${a}" == "YES" ]] || die "Aborted by operator."
}
