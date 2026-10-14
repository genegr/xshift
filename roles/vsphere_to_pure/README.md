# Role: vsphere_to_pure

Stage 1 of the migration. For a **powered-off** vSphere VM, clones each flat VMDK onto an
equally-sized **Pure FlashArray** volume using ESXi `vmkfstools` — which triggers VAAI **XCOPY**
when source and destination are on the same array (array-offloaded, no network copy). Then detaches
the volume so Cinder can import it in stage 2, and writes a stage 2 mapping fragment.

Produces Pure volumes named `<vm>-disk-<key>`: `<vm>` is `target_vm_name` lowercased with every
character other than `a-z`, `0-9` and `-` folded to `-` (so `Web Server 01` becomes
`web-server-01`), `<key>` is the vCenter disk key (`0`, `1`, ...), which does not shift when a
disk is skipped.

## Key variables (see `defaults/main.yml` and `group_vars/all`)

| Variable | Purpose |
|----------|---------|
| `dry_run` | `true` (default) plans only; `-e dry_run=false` executes |
| `target_vm_name` | VM to migrate |
| `vcenter_*` / `fa_*` | vCenter and FlashArray connection |
| `fail_on_snapshots` | `true` (default): stop when the VM has snapshots; `false` clones the current state of each chain |
| `allow_skipped_disks` | `false` (default): stop when any disk is not a flat VMDK; `true` migrates the flat ones |
| `xcopy_required` | `true` (default): stop when the clone could not be array-offloaded (see below) |
| `xcopy_min_throughput_mib` | Warn when a clone ran below this rate (MiB/s); `0` (default) disables |
| `pure_host_name` | Empty (default) = find the FlashArray host object by the ESXi host's initiators; set to force one |
| `pure_host_auto_create` / `pure_host_create_name` | Create the host object when none matches (default `true`, named after the inventory host) |
| `target_esxi_host` | Empty (default) = auto-detect the ESXi host from the VM's placement; set to a `hypervisors` member to force one |
| `pure_naa_prefix` | Pure OUI prefix used to find the device on ESXi |
| `mapping_output_dir` | Where the stage 2 mapping fragment is written (`generated/`); empty skips it |
| `boot_disk_index` | vCenter disk key marked `boot: true` in the fragment (default `0`) |

## Flow

1. Read power state, NICs and snapshots from vCenter; stop if powered on (real run) or snapshotted.
2. Read the disk layout; split flat VMDKs from other backings and report or stop on the latter.
3. Resolve the ESXi host and the FlashArray host object (below).
4. Check the XCOPY prerequisites (below).
5. Per flat disk: create the volume, connect it to the host object, rescan, wait for the device,
   check its VAAI clone status, `vmkfstools -i ... -d rdmp:` clone, report duration and
   throughput; always remove the temporary RDM and disconnect the volume.
6. Write `generated/mapping-<vm>.yaml` for stage 2 (also on dry runs).

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

## XCOPY prerequisites
ESXi offloads a `vmkfstools` clone to the array only when all of these hold, and otherwise copies
through the host without saying so:

- `DataMover.HardwareAcceleratedMove` is `1` on the ESXi host (read over SSH, dry run included);
- every source datastore is a VMFS volume whose extent is a device on `fa_url` (the extent's NAA
  serial is looked up on the array);
- the destination device reports `Clone Status: supported` in `esxcli storage core device vaai
  status get` once it is visible (real run only).

With `xcopy_required: true` (default) a failed prerequisite stops the run; with `false` it is
reported and the clone proceeds as a host-side copy. After each clone the duration and the average
throughput are printed; `xcopy_min_throughput_mib` turns a low rate into a warning. The esxtop VAAI
counters (`CLONE_RD`, `CLONE_WR`, `CLONE_F` on the device) remain the authoritative proof that the
array did the copy.

## Stage 2 hand-off
`generated/mapping-<vm>.yaml` holds one `vm_migrations` entry built from vCenter: `flavor_auto`
with vCPU and RAM, the NIC portgroup names (to be replaced with Neutron networks), one disk per
cloned VMDK with the boot disk carrying `image_properties` (`hw_firmware_type` from the VM's
firmware, plus `hw_machine_type: q35` for UEFI and `os_secure_boot: required` when Secure Boot is
on; `hw_disk_bus: scsi`, `hw_scsi_model: virtio-scsi`). Review it before use: a guest without
virtio drivers needs `hw_disk_bus: sata` / `hw_vif_model: vmxnet3` instead (see the top-level
README). Distributed-switch NICs appear by portgroup key (`dvportgroup-NNN`).

## Notes
- Only `FlatVer2` (flat VMDK) disks are processed.
- Execution is wrapped in `block`/`rescue`/`always`: the failure message names the failed task and
  its error; the temp RDM removal, volume disconnect and final rescan run even if the clone fails.
- The volume's serial and NAA come from the `purefa_volume` result (collection >= 1.14), so the
  role never lists the array's volumes.
