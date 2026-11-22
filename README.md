# MRP 19.33: two-node Data Guard (DG Broker), grid + oracle users

MRP 19.33.0.0.261117 applied **in place**, standby first. Companion of `oracle-dataguard-oop-patch-19c`.

- Grid home: GI MRP 40196150 with `opatchauto`. DB home: DB MRP 40196156 with `opatch napply` (`DB_PATCH_METHOD=GI_MRP` switches to `opatchauto -binary`). Never both on one home.
- `datapatch -verbose` runs once, on the current primary, after both nodes are patched. Never on a standby.

## Setup

1. Put the **same** `patch.conf` and scripts at the same path on both nodes (outside `/root`). Set `PRIMARY_HOST`, `STANDBY_HOST`, `*_DB_UNIQUE_NAME`, `*_SID` (and `*_TNS` if the alias differs from the DB_UNIQUE_NAME), `GRID_HOME`, `DB_HOME`, `PATCH_LOC`, `LOG_DIR`, `BACKUP_DIR`. Leave `DB_NAME` and `DB_SID` empty; they are set per node.
2. Stage the two MRP zips (and the OPatch zip if needed) on **each** node. No shared storage or SSH between nodes is needed.
3. Take a VM snapshot or RMAN backup of both nodes. Run as root. Add `--dry-run` to any script first.

## Run order

`./dg_mrp_runbook.sh` prints this with your hostnames; `--status` shows this node's phase markers.

| Step | Node | Script |
|---|---|---|
| 1 | both | `01_prep_local.sh` |
| 2 | standby | `02_apply_standby_node.sh` (redo apply off, stop, patch, start, apply on) |
| 3 | primary | `03_switchover.sh` (needs SYS password) |
| 4 | old primary, now standby | `02_apply_standby_node.sh` again |
| 5 | current primary | `04_datapatch_primary.sh` |
| 6 | current primary | `05_switchback.sh` (optional, restores original roles) |
| 7 | both | `06_verify_local.sh` |
| 8 | both | `07_security_local.sh` (optional), `08_aide_local.sh` (optional, last) |

`rollback_local.sh --yes` rolls a node back: standby side first, and run it last on the final primary so `datapatch -verbose` rolls the SQL back. Its header has the order.

## Password and hardened hosts

- The SYS password is only required for the switchover. It is read with `read -s` (or `DG_SYS_PASSWORD`), goes to `dgmgrl` on stdin and is never logged or stored.
- `01`, `02`, `04`, `08` and `rollback_local.sh` auto-detach under `systemd-run` (unit `mrp-<script>`, `AUTO_DETACH="yes"` in `patch.conf`), so a closed SSH session, `TMOUT` or `KillUserProcesses=yes` cannot kill them halfway. Detached runs use `dgmgrl /` OS authentication and cannot prompt for a password. Watch the log named in the output; `systemctl stop` the unit afterwards. `--foreground` stays attached. `03` and `05` need the SYS password and always run in the foreground.
- If `opatchauto` was interrupted (Grid patched, CRS down), re-run `02 --from-step 4`: it runs `opatchauto resume`.
- `CHOPT_REAPPLY` is `no` here: an option that comes back TRUE fails `06` with the per-node fix, since chopt needs a restart.
- Expect this after every MRP: the relink turns `olap` and `rat` back on, so `06` fails once per node. Fix on each node, then re-run `06`: set redo apply off (`dgmgrl / "edit database '<db_unique_name>' set state='apply-off'"`), `srvctl stop database` as grid, `chopt disable olap` and `chopt disable rat` as oracle, `srvctl start database`, set apply on again. Do the standby first.
- `06` also fails if the Clusterware node patch level differs from the release patch level (`crsctl query crs softwarepatch` against `releasepatch`). That means the `opatchauto` postpatch step did not finish: read the opatchauto and `crs_postpatch` logs, then `opatchauto resume`.

## Files

`patch.conf`, `lib_mrp.sh`, `lib_dg.sh` (shared functions), `dg_mrp_runbook.sh`, `01_` to `08_` scripts, `rollback_local.sh`.

See the repository README for the readme discrepancies (GI MRP says RU 19.32, DB MRP says 19.33) and the cut-off patch tables in the PDFs.
