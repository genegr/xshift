---
name: migration-recovery
description: Diagnose a failed xshift run and bring the lab back to a clean state - read the real failure, find leftovers read-only (FlashArray volumes and host connections, temporary RDM files on the datastore, dead ESXi paths, auto-created host object, Cinder volumes in error, instances, auto-created flavor), decide between re-run and cleanup, and what never to delete. Use when stage 1 or stage 2 failed, a run was interrupted, or a lab needs resetting.
---

# Recovering a failed run

## 1. Read the real cause

Ansible's output ends with the failing task. Stage 1 wraps each disk in `block`/`rescue`/`always`: the rescue prints `Migration of disk <n> (<volume>) failed in task '<task>': <cause>`, and the `always` section then ran the cleanup. Stage 2 stops at the first failing task of the VM; a manage failure names the volume and the unmanage command.

If the process was killed (container stopped, connection lost), `always` did **not** run: assume leftovers.

## 2. Inventory the leftovers (read-only first)

| Leftover | Stage | How to look |
|----------|-------|-------------|
| Volume `<vm slug>-disk-<key>` still connected to the ESXi host's host object | 1 | FlashArray REST: `GET /volumes?names=<name>` and `GET /connections?volume_names=<name>` (login with the `api-token` header, then `x-auth-token`; `fa_rest_version` is in the role defaults) |
| Volume exists but the disk was only partly cloned | 1 | the disk's task failed after `Create volume`; the volume has no data worth keeping, but see "Never" first |
| Temporary RDM files `<vm slug>_temp_<key>.vmdk` and `-rdmp.vmdk` in the source datastore root | 1 | `vmware_vmdk_info` with `path: "[<datastore>] <vm slug>_temp_<key>.vmdk"` through the ESXi host's API; `vmdk.exists` |
| The LUN still visible on the ESXi host (dead paths) | 1 | `vmware_host_scsidisk_info` through vCenter, look for the NAA; a rescan clears dead paths |
| Host object auto-created by this run (`pure_host_create_name`, personality `esxi`) | 1 | `GET /hosts?names=<name>`; it is meant to stay for later runs |
| Cinder volume in `error` or `error_managing` | 2 | `openstack volume show <name>`; the cinder-volume log on the backend host has the cause |
| Instance created, volume attached | 2 | `openstack server show <vm>`, `openstack volume show` |
| Flavor `migrated-<vm>` (from `flavor_auto`) | 2 | `openstack flavor show migrated-<vm>` |

Never print tokens or passwords while inspecting: read them from the vault or the environment inside the tool you run, and do not echo them.

## 3. Choose the action

- **Re-run stage 1 for the same VM.** It is meant to be repeatable: `purefa_volume` reuses a volume of the same name that stage 2 has not yet managed, and the clone runs with `force: true`, so a leftover temporary RDM is replaced. Fix the cause first. If the volume is still connected or the files are still there from a killed run, clean those up (below) or just re-run and let the `always` section do it.
- **Disconnect a leftover volume:** `everpure.flasharray.purefa_host` with the host object name **and** `volume:`, `state: absent`. Then rescan the ESXi host (`vmware_host_scanhba` through vCenter).
- **Remove leftover RDM files:** `vsphere_file state: absent` through the ESXi host's API, `datacenter: ha-datacenter`, one call for `<name>.vmdk` and one for `<name>-rdmp.vmdk`. The LUN data is not touched.
- **Stage 2 `error_managing`:** `openstack volume delete --remote <name>` unmanages it again without touching the array. Fix the backend cause, then re-run: manage is idempotent.
- **After a successful manage the array volume was renamed** `volume-<id>-cinder`: the stage 1 name no longer exists on the array, so a stage 1 re-run would create a new volume. Treat the Cinder volume as the owner of that data.
- **Image properties wrong on a volume that is already attached:** delete the instance (the volume is kept, `terminate_volume: false`), fix the mapping, re-run stage 2.
- **Start over completely:** unmanage in Cinder first (`--remote`), then destroy the array volume only if this run created it and you have the owner's OK.

## 4. Never

- **Objects you did not create.** The array may be shared. Stage 1 volumes are `<vm slug>-disk-<key>`; do not touch other names, and never use a wildcard delete.
- **Eradicate.** Destroying a volume leaves it in the array's destroy bin, recoverable; eradicating does not. Do not eradicate without the owner's explicit OK.
- **`purefa_host state: absent` without `volume:`.** That deletes the host object.
- **Delete an array volume that Cinder manages** (named `volume-<id>-cinder`): unmanage through Cinder.
- **Delete the source VM.** xshift never needs to; it only reads it.
- **Retry blindly.** One failing login or credential repeated in a loop can lock an account: stop on an authentication error and find the cause.

After cleanup, repeat the checks of the table and confirm nothing from the failed run remains, then re-run from stage 1 (or stage 2 when stage 1 was complete).
