# Role: vsphere_to_pure

Stage 1 of the migration. For a **powered-off** vSphere VM, clones each flat VMDK onto an
equally-sized **Pure FlashArray** volume using ESXi `vmkfstools` — which triggers VAAI **XCOPY**
when source and destination are on the same array (array-offloaded, no network copy). Then detaches
the volume so Cinder can import it in stage 2.

Produces Pure volumes named `<target_vm_name lowercased>-disk-<index>`.

## Key variables (see `defaults/main.yml` and `group_vars/all`)

| Variable | Purpose |
|----------|---------|
| `dry_run` | `true` (default) plans only; `-e dry_run=false` executes |
| `target_vm_name` | VM to migrate |
| `vcenter_*` / `fa_*` / `pure_host_name` | vCenter and FlashArray connection + host object |
| `target_esxi_host` | ESXi host (in `hypervisors`) that runs vmkfstools |
| `pure_naa_prefix` | Pure OUI prefix used to find the device on ESXi |

## Notes
- Only `FlatVer2` (flat VMDK) disks are processed.
- Execution is wrapped in `block`/`always`: the temp RDM removal, volume disconnect, and final
  rescan run even if the clone fails.
