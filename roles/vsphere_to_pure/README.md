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
| `vcenter_*` / `fa_*` | vCenter and FlashArray connection |
| `pure_host_name` | Empty (default) = find the FlashArray host object by the ESXi host's initiators; set to force one |
| `pure_host_auto_create` / `pure_host_create_name` | Create the host object when none matches (default `true`, named after the inventory host) |
| `target_esxi_host` | Empty (default) = auto-detect the ESXi host from the VM's placement; set to a `hypervisors` member to force one |
| `pure_naa_prefix` | Pure OUI prefix used to find the device on ESXi |

## ESXi host selection
vmkfstools runs on the host vCenter reports for the VM (`hw_esxi_host`), which is matched to a
member of the `hypervisors` group by inventory name, `ansible_host`, or the optional host var
`esxi_vcenter_name`; short hostnames match FQDNs. The run stops, dry run included, if no single
host matches.

## FlashArray host object selection
The host object is found by initiator, not by name: the ESXi host's FC port WWNs and iSCSI IQN are
read from vCenter and compared with the array's own host objects (objects stretched in from other
arrays are ignored). A WWN match wins over an IQN match. If nothing matches, a host object is
created with the WWNs (or the IQN when the host has no FC ports) and personality `esxi`; a dry run
only reports it. The run stops if several objects match, or if the name to create is already taken.
NVMe NQNs are not used, because the RDM-based clone needs a SCSI path. This lookup reads the array
on dry runs too, so `fa_url` and `fa_api_token` are always required.

## Notes
- Only `FlatVer2` (flat VMDK) disks are processed.
- Execution is wrapped in `block`/`always`: the temp RDM removal, volume disconnect, and final
  rescan run even if the clone fails.
