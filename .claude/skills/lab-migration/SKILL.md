---
name: lab-migration
description: Run a real xshift migration on a lab to test a change - choose a safe VM, dry run, stage 1 execute, verify the array volume, RDM files and offload evidence, review the generated mapping, stage 2 dry run and execute, verify the instance, and record the result. Lists what a first live run of the vmware_vmdk_clone path must confirm. Use when a change needs proof against real vCenter, ESXi, FlashArray or OpenStack, or when reproducing a lab failure.
---

# Lab migration end to end

Lab facts (vCenter, ESXi hosts, array, OpenStack endpoint, credentials location, the VM to use) belong in your `CLAUDE.local.md`; never put them in a committed file. Start from skill `verify-changes` so the change is clean offline first.

## 0. Before touching anything

- **Get the person's go-ahead** for each real (`dry_run=false`) stage on a named VM. A dry run needs no approval but does log in to real systems.
- **Pick a throwaway VM:** powered off, no snapshots (or `fail_on_snapshots=false` on purpose), disks on a datastore backed by the **same FlashArray** as the target volumes, a flat VMDK, ideally small. A VM with RDM or sparse disks stops the run unless `allow_skipped_disks=true`.
- **Shared array:** only touch objects this run creates. The stage 1 volumes are named `<vm slug>-disk-<key>`; do not eradicate anything.
- **Preconditions:** the VM's ESXi host is in the `hypervisors` inventory group with its root login (`ansible_password` from the vault); the ESXi host has `DataMover.HardwareAcceleratedMove=1`; a FlashArray host object holds its initiators, or auto-create is acceptable (it creates an `esxi` personality host object).
- Build the image and put `vault.yml` in place (copy `vault.example.yml`, fill, `ansible-vault encrypt`).

## 1. Stage 1

```bash
docker build -t vsphere-os-migration .
run() { docker run --rm -it -v "$PWD":/work -w /work vsphere-os-migration "$@"; }
run ansible-playbook migrate_vm.yaml --ask-vault-pass -e target_vm_name=<vm>                 # dry run
run ansible-playbook migrate_vm.yaml --ask-vault-pass -e target_vm_name=<vm> -e dry_run=false   # after the go-ahead
```

Read the dry run first: ESXi host, FlashArray host object (existing or to be created), the XCOPY prerequisites, the per-disk plan, and the mapping fragment path. Stop on any problem it reports instead of overriding it with `xcopy_required=false`, unless testing exactly that path.

## 2. Verify stage 1 (read-only)

- **Output:** each disk reports the hardware acceleration status of the new device and `Cloned <size> ... about <n> MiB/s`. On one Pure lab a 50 GiB thin VMDK cloned in about 20 s (roughly 2.5 GiB/s); a few hundred MiB/s suggests the copy went through the host.
- **Offload proof:** ask the person to read the esxtop VAAI counters on the ESXi host while the clone runs (`CLONE_RD`, `CLONE_WR`, `CLONE_F` for the device). The throughput figure is only a heuristic.
- **Array:** `<vm slug>-disk-<key>` exists, its size is the VMDK capacity rounded up to a whole GiB, and it has **no host connection** (the `always` section disconnected it). See `migration-recovery` for the read-only REST calls.
- **Datastore:** no `<vm slug>_temp_<key>.vmdk` / `-rdmp.vmdk` left in the source datastore root (`vmware_vmdk_info` on the path reports `exists: false`).
- **ESXi:** the LUN is no longer listed after the final rescan.
- **Mapping:** `generated/mapping-<vm slug>.yaml` exists. Review it: replace portgroup names with Neutron networks, check flavor, key pair, security groups, firmware and `image_properties`.

## 3. Stage 2

```bash
set -a; source admin-openrc.sh; set +a        # or OS_CLOUD
# pass the OS_* variables into the container (see the README), then:
run ansible-playbook migrate_to_openstack.yaml -e mapping_file=generated/mapping-<vm>.yaml                 # dry run
run ansible-playbook migrate_to_openstack.yaml -e mapping_file=generated/mapping-<vm>.yaml -e dry_run=false
```

Verify: the volumes are Cinder volumes (`in-use` once attached), the boot volume carries the image properties, the instance is `ACTIVE`, and its console shows the guest booting. A guest that does not boot is usually firmware or driver related: skill `openstack-import`.

## 4. Open items for the first live run of the vmware_vmdk_clone path

Report each one back (README "Limitations", the PR, and `CLAUDE.local.md`):
1. **`vStorageSupport` of a FlashArray LUN.** Does it read `vStorageSupported` while XCOPY works? If it reads unknown or unsupported on a working setup, the `xcopy_required` device check needs relaxing.
2. **Re-run on an existing volume.** `purefa_volume state: present` on a volume that already exists crashed in `everpure.flasharray` 1.45.1 on another lab (`_volfact`). Stage 1's re-run path relies on it. Check with the version the image installed (`ansible-galaxy collection list`).
3. **The clone itself** through the ESXi API with the inventory login, on your ESXi version, and the temp RDM cleanup (`ha-datacenter`).

## 5. Record it

Write what you ran, the versions (vCenter, ESXi, Purity, OpenStack), the measured throughput and any surprise into your `CLAUDE.local.md`, and into the PR description. If the run found a lasting trap, add it to the right skill.
