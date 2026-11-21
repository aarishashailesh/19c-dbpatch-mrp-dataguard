#!/usr/bin/env bash
# =============================================================================
# dg_mrp_runbook.sh : prints the run order for the two nodes and the status of this node.
# It executes nothing.
#
# USAGE:
#   ./dg_mrp_runbook.sh [--status]
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/patch.conf"
P="${PRIMARY_HOST}"; S="${STANDBY_HOST}"
D="${SCRIPT_DIR}"
if [[ "${1:-}" == "--status" ]]; then
  echo "Node $(hostname -s): phase markers in ${STATUS_DIR}"
  for n in 1:prep 2:apply 3:datapatch 4:verify 5:security 6:aide; do
    f="${STATUS_DIR}/phase${n%%:*}.done"
    printf '  %-10s %s\n' "${n##*:}" "$( [[ -f "${f}" ]] && cat "${f}" || echo "not done")"
  done
  exit 0
fi
cat <<TXT
MRP ${MRP_LABEL}: standby-first, in place, two nodes (${P} = primary, ${S} = standby at the start)
All scripts run as root from ${D}. Add --dry-run to any of them first. --detach (systemd-run) is
available where no password is needed; remove the unit afterwards: systemctl stop mrp-<script>.

 A. Preparation (online, no outage)
  1. ${P}   ${D}/01_prep_local.sh
  2. ${S}   ${D}/01_prep_local.sh

 B. Standby first
  3. ${S}   ${D}/02_apply_standby_node.sh          patches the standby binaries (this node's outage)
  4. ${P}   ${D}/03_switchover.sh                  needs the SYS password; ${S} becomes the primary
  5. ${P}   ${D}/02_apply_standby_node.sh          the old primary is now a standby: same script
  6. ${S}   ${D}/04_datapatch_primary.sh           datapatch on the current primary (both nodes patched)

 C. Roles and validation
  7. ${S}   ${D}/05_switchback.sh                  optional: restore ${P} as the primary
  8. both   ${D}/06_verify_local.sh
  9. both   ${D}/07_security_local.sh              optional: fips.ora and extproc
 10. both   ${D}/08_aide_local.sh                  optional, last: AIDE baseline (30 to 60 minutes)

 Rollback (not part of the normal run): ${D}/rollback_local.sh --yes   (standby side first, see its header)
 Status of this node: ${D}/dg_mrp_runbook.sh --status
TXT
