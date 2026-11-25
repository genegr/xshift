---
name: esxi-disk-clone
description: How xshift stage 1 talks to ESXi without SSH - vmware_vmdk_clone / vmware_vmdk_info (community.vmware PR #2623, pinned fork commit), the RDM clone and its cleanup with vsphere_file, the vCenter-side device wait and hardware-acceleration (vStorageSupport) check, DataMover read, credentials, and how to bump or replace the pinned collection. Use when touching migrate_disk.yml, check_xcopy.yml, resolve_*.yml, requirements.yml, or anything that reaches an ESXi host.
---

# ESXi disk operations (no SSH)

Stage 1 used to SSH to the ESXi host and run `vmkfstools -i ... -d rdmp:` and `esxcli`. It no longer does, and should not again: no SSH to enable, no `sshpass`, no host key handling, and the same code path works from a container. Everything goes through two APIs:

| Need | How |
|------|-----|
| Clone a VMDK onto the new LUN as a physical RDM | `community.vmware.vmware_vmdk_clone` with `disk_format: rdmp`, `device: <naa>`, **connected to the ESXi host** |
| Check a source disk (exists, regular VMDK, size) | `community.vmware.vmware_vmdk_info`, connected to the ESXi host, also on dry runs |
| Remove the temporary RDM files | `community.vmware.vsphere_file` `state: absent`, connected to the ESXi host, `datacenter: ha-datacenter` |
| Rescan HBAs | `vmware_host_scanhba` through vCenter |
| Wait for the LUN, read its hardware acceleration status | `vmware_host_scsidisk_info` through vCenter |
| Read `DataMover.HardwareAcceleratedMove` | `vmware_host_config_info` through vCenter |

## Rules learned the hard way

- **The clone must log in to the ESXi host, not vCenter.** vCenter ignores the destination spec of the copy call (an RDM target would silently become a flat VMDK), so the module refuses an RDM clone through vCenter. Use `hostname: "{{ esxi_exec_api_host }}"`, user and password from the `hypervisors` inventory host (`ansible_host`, `ansible_user`, default `root`, `ansible_password`), `validate_certs: "{{ esxi_validate_certs }}"`. The host must mount the source datastore and see the LUN.
- **Paths** are datastore paths: vCenter's `backing_filename` (`[ds1] vm/vm.vmdk`) is used as the source unchanged. The temporary RDM is `[<datastore>] <vm slug>_temp_<disk key>.vmdk` in the datastore root, plus its mapping file `...-rdmp.vmdk`.
- **`force: true` is required for re-runs.** The module's idempotency looks at the destination path only: an existing destination is left alone, not compared with the source. With `force` it deletes the destination first and never one that a VM uses. The LUN content is overwritten; the LUN must be at least as large as the source and must not hold a VMFS datastore.
- **No duration is returned.** The throughput report times the task with `now()`.
- **Cleanup goes through the ESXi host.** vCenter's `/folder` service refuses `.vmdk` deletes, and `vsphere_file` cannot delete directories, so delete the two files by name (`.vmdk`, `-rdmp.vmdk`) with `datacenter: ha-datacenter`. A file that is already absent is `changed: false`, not an error. Removing an RDM's files leaves the LUN data alone.
- **`vmware_host_scsidisk_info` is keyed by the host name vCenter uses.** Read it with `.values() | first`, not by the inventory name. It lists the new LUN only after the rescan has seen it, hence the `until`/`retries` poll sized from `device_wait_timeout`.
- **`vStorageSupport` is the whole-device acceleration status** (`vStorageSupported`, `vStorageUnsupported`, `vStorageUnknown`). It replaced `esxcli ... vaai status get`, whose per-primitive "Clone Status" needed SSH. With `xcopy_required: true` anything but `vStorageSupported` stops the run. It has not yet been confirmed on a real FlashArray LUN in this repository (see skill `lab-migration`).
- **Passwords stay out of facts** (`set_fact` prints them at `-v`); read `hostvars[esxi_exec_host]` in the module call.
- **A VM with snapshots clones its current chain state**, not the snapshots; `fail_on_snapshots` decides whether that stops the run.

## The pinned collection

`requirements.yml` installs community.vmware from the `genegr` fork, branch `feature/vmdk-info-clone`, pinned by commit (not yet in a Galaxy release; PR: ansible-collections/community.vmware#2623). That collection needs ansible-core 2.21 or later and `vmware.vmware` (pinned beside it). `ansible-galaxy` clones it, so the image has `git`.

To bump the pin:
1. Take the new commit hash from the fork branch and edit the `version:` of the git entry in `requirements.yml`. The Dockerfile reads the same file; nothing else changes.
2. Rebuild the image and check: `ansible-doc community.vmware.vmware_vmdk_clone` resolves, then run skill `verify-changes`. Read the module's option list again if the PR changed it.
3. If the module's behavior changed, update `mock/template.py` and `assert_flow.py` under `verify-changes`.

Once the module is in a community.vmware release (its docs say `version_added: 7.1.0`), replace the git entry with `community.vmware` at that version range, drop the `git` package from the Dockerfile if nothing else needs it, and update the README prerequisites and this skill.

## Where the code is

`check_xcopy.yml` (prerequisites from facts), `resolve_pure_host.yml` (the vCenter reads), `resolve_esxi_host.yml` (`esxi_exec_*`), `migrate_disk.yml` (create, present, rescan, wait, clone, clean up), `main.yml` (the `vmware_vmdk_info` source check).
