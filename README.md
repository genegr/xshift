# xshift

**Storage-offloaded vSphere → OpenStack VM migration via Pure FlashArray XCOPY.**

Fast, storage-offloaded cold migration of virtual machine disks from **VMware vSphere** to
**OpenStack**, using **Pure Storage FlashArray** VAAI **XCOPY** to move the data at array speed
instead of copying it over the network.

Instead of streaming each VMDK across the wire (slow, network-bound), this project asks the
FlashArray to duplicate the blocks internally. A multi-hundred-GB disk that would take hours over
NFS/iSCSI copy is reduced to minutes (or seconds on thin/deduplicated data).

> **Status:** both stages are implemented. Stage 1 (vSphere → FlashArray, `migrate_vm.yaml`) clones
> each VMDK onto a Pure volume via XCOPY and writes a mapping fragment for stage 2. Stage 2
> (`migrate_to_openstack.yaml`) imports those Pure volumes into Cinder via *manage-existing*, sets
> the image properties Nova needs, and boots each VM with Nova *boot-from-volume* — validated
> end-to-end against a kolla-ansible OpenStack 2026.1 lab (see [`openstack-lab/`](openstack-lab/)).
> The XCOPY prerequisite checks and the generated mapping were added afterwards and have not yet
> been exercised against hardware; see [Limitations](#limitations--known-issues).

---

## Table of contents

- [How it works](#how-it-works)
- [Architecture](#architecture)
- [The migration pipeline](#the-migration-pipeline)
- [What is checked before anything is copied](#what-is-checked-before-anything-is-copied)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [Usage](#usage)
- [Safety & security notes](#safety--security-notes)
- [Limitations & known issues](#limitations--known-issues)
- [Roadmap](#roadmap)
- [Repository layout](#repository-layout)
- [Disclaimer](#disclaimer)

---

## How it works

The core trick is **VAAI XCOPY** (SCSI `EXTENDED COPY`). When the source VMDK and the destination
volume both live on the **same FlashArray**, ESXi can tell the array to copy blocks device-to-device
without pulling them up through the hypervisor and back down. The array does the work.

The playbook wires this up for you:

1. It reads the VM's disk layout from vCenter.
2. For each disk, it provisions a matching raw volume on the FlashArray and presents it to an ESXi
   host as a device.
3. It runs `vmkfstools -i <source.vmdk> -d rdmp:<device>` on that ESXi host. This clone operation is
   what triggers XCOPY, landing a raw, bootable copy of the disk onto the FlashArray volume.
4. It cleans up the temporary RDM mapping and detaches the volume from ESXi.

The result is a **standalone FlashArray volume that contains the VM's disk**, ready to be imported
into OpenStack Cinder and attached to a Nova instance — with **no second data copy**, because Cinder
can *manage* the existing backend volume in place.

## Architecture

```
                +-------------------+          community.vmware
                |   vCenter Server  |<------------------------------+
                +-------------------+                               |
                        ^                                           |
                        | (VM & disk inventory, snapshots,          |
                        |  power state, HBA rescan)                 |
                        |                                           |
   +--------------------+----------+     SSH (vmkfstools,  +--------+--------------+
   |  Ansible control node         |      esxcli)          |      ESXi host        |
   |  (this project, in Docker)    |---------------------->|  (mounts the VMFS     |
   |                               |                       |   datastore + volume) |
   |  community.vmware             |                       +-----------+-----------+
   |  everpure.flasharray          |                                   |
   |  openstack.cloud + CLI        |    REST API                       | VAAI XCOPY
   +---------------+---------------+----------------+                  | (block copy,
                   |                                |                  |  array-internal)
                   | REST API                       v                  v
                   |                     +---------------------------------------+
                   +-------------------->|          Pure FlashArray              |
                                         |   source VMFS datastore <--XCOPY-->   |
                                         |   destination raw volume              |
                                         +--------------------+------------------+
                                                              |
                                              Cinder manage   |  same volume,
                                              + Nova BFV      v  no re-copy
                                         +---------------------------------------+
                                         |               OpenStack               |
                                         |   Cinder volume  ->  Nova instance    |
                                         +---------------------------------------+
```

**Components**

| Component | Role |
|-----------|------|
| Ansible control node | Orchestrates everything; runs inside Docker (see [Usage](#usage)). |
| vCenter | Source of truth for VM inventory, disk layout, snapshots, firmware, power state; performs HBA rescans. |
| ESXi host | Executes `vmkfstools` and read-only `esxcli` checks over SSH; must mount both the source datastore and the new volume. |
| Pure FlashArray | Provides both the source datastore and the destination volume; performs the XCOPY. |
| OpenStack (Cinder/Nova) | Imports the landed volume and boots the migrated instance. |

## The migration pipeline

```
 vSphere VM (powered off, no snapshots)
        │
        ▼
 [1] Read disk layout, NICs, firmware from vCenter      ── stage 1
        │
        ▼
 [2] Check XCOPY prerequisites (host setting, same array)
        │
        ▼
 [3] Provision matching volume on FlashArray
        │
        ▼
 [4] Present volume to ESXi + rescan + VAAI clone status
        │
        ▼
 [5] vmkfstools clone → XCOPY block copy (+ throughput report)
        │
        ▼
 [6] Detach volume + cleanup RDM
        │
        ▼
 [7] Write generated/mapping-<vm>.yaml  ── review, map networks
        │
        ▼
 [8] Validate mapping against OpenStack                 ── stage 2
        │
        ▼
 [9] Cinder manage-existing imports the volume + image properties
        │
        ▼
 [10] Nova boot-from-volume creates the instance, data volumes attached
        │
        ▼
 OpenStack instance running on the same data
```

### Mapping vSphere → OpenStack

Because the data already sits on a FlashArray volume that OpenStack's Cinder driver also manages,
the import needs **no data movement** — only metadata:

- **`openstack volume create --remote-source source-name=<vol> --host <host@backend#pool>`**
  imports the pre-existing backend volume into Cinder, producing a first-class Cinder volume.
- **`openstack volume set --image-property`** gives that volume the metadata Nova reads when it
  boots from a volume: `hw_firmware_type` (`uefi` for an EFI VM, otherwise the instance never finds
  its loader), `hw_machine_type`/`os_secure_boot` for Secure Boot, `hw_disk_bus`, `hw_scsi_model`,
  `hw_vif_model`. Nova reads them once, when the instance is created.
- **Nova boot-from-volume** then launches an instance whose root disk *is* that Cinder volume.

The migration is driven by a per-VM **mapping** ([`mapping.example.yaml`](mapping.example.yaml))
that translates vSphere concepts into OpenStack concepts: flavor from CPU/RAM, portgroup → Neutron
network, each VMDK → a Cinder volume with a boot flag and image properties. Stage 1 writes a
starting point for it from what vCenter reported (`generated/mapping-<vm>.yaml`); you replace the
portgroup names with Neutron networks and pass it to stage 2.

## What is checked before anything is copied

| Check | Stage | On failure |
|-------|-------|------------|
| VM is powered off | 1 (real run) | stop |
| VM has no snapshots (`fail_on_snapshots`) | 1 | stop, or clone the current state |
| Every disk is a flat VMDK (`allow_skipped_disks`) | 1 | stop, or migrate the flat ones |
| The VM's ESXi host is exactly one `hypervisors` member | 1 | stop |
| A FlashArray host object holds the ESXi host's WWNs/IQN, or can be created | 1 | stop |
| `DataMover.HardwareAcceleratedMove` is `1` on the ESXi host (`xcopy_required`) | 1 | stop, or host-side copy |
| Every source datastore's extent is a volume on `fa_url` (`xcopy_required`) | 1 | stop, or host-side copy |
| The new device reports VAAI `Clone Status: supported` (`xcopy_required`) | 1 (real run) | stop, or host-side copy |
| Mapping shape: one boot disk, networks, flavor or `flavor_auto` | 2 | stop |
| Flavor and networks exist | 2 | stop |
| Each volume is a Cinder volume or `safe_to_manage` on the backend | 2 | stop |

After each clone, stage 1 prints its duration and average throughput. ESXi falls back to a
host-side copy silently when XCOPY is not eligible, so an unexpectedly slow clone is worth a look
at the esxtop VAAI counters (`CLONE_RD` / `CLONE_WR` / `CLONE_F`); `xcopy_min_throughput_mib`
turns a low rate into a warning.

## Prerequisites

**On the FlashArray / vSphere side**
- The **source VMDK datastore and the destination volume live on the same FlashArray** (this is what
  makes XCOPY offload possible). Stage 1 verifies it; with `xcopy_required: false` a cross-array
  copy still works but falls back to a normal, slower copy through the ESXi host.
- VAAI hardware acceleration enabled on the ESXi hosts (`DataMover.HardwareAcceleratedMove`).
- SSH enabled on the target ESXi host (used to run `vmkfstools` and read-only `esxcli` checks).
- FC or iSCSI connectivity between the ESXi host and the FlashArray. The array **host object** is found
  by the ESXi host's WWNs/IQN and created if absent (set `pure_host_name` to force a specific one).
- A FlashArray **API token** with volume/host management rights.
- A vCenter account that can read VM inventory and trigger storage rescans.

**On the OpenStack side**
- A Cinder backend using the Pure driver against the same array, and the `host@backend#pool` name
  of that backend (`cinder get-pools`).
- Admin credentials (manage-existing and the manageable listing are admin operations).

**On the control node** (all provided by the Docker image — see [Usage](#usage))
- Ansible (`ansible-core` 2.17 or 2.18).
- Collections: `community.vmware`, `everpure.flasharray` (formerly `purestorage.flasharray`) and
  `openstack.cloud`, pinned in [`requirements.yml`](requirements.yml).
- Python libraries: `pyvmomi`, `py-pure-client`, `openstacksdk` and a `python-openstackclient`
  recent enough for `volume create --remote-source`, pinned in [`requirements.txt`](requirements.txt).

## Configuration

Shared configuration lives in [`inventory/group_vars/all/main.yml`](inventory/group_vars/all/main.yml);
hosts/groups in [`inventory/hosts.yml`](inventory/hosts.yml); secrets in `vault.yml` (copy from
[`vault.example.yml`](inventory/group_vars/all/vault.example.yml) and `ansible-vault encrypt`).
Per-role tunables are in each role's `defaults/main.yml` and documented in the role READMEs. Key
variables:

| Variable | Description |
|----------|-------------|
| `dry_run` | `true` (default) plans and validates without making changes. Override with `-e "dry_run=false"` to execute. |
| `vcenter_hostname` / `vcenter_username` / `vcenter_password` | vCenter connection details. |
| `vcenter_datacenter` | Datacenter containing the target VM. |
| `target_vm_name` | The VM to migrate (stage 1 handles one VM per run). |
| `fa_url` / `fa_api_token` | FlashArray management endpoint and API token. |
| `pure_host_name` | Optional: force a FlashArray host object. Empty (default) matches it by the ESXi host's WWNs/IQN and creates it if absent. |
| `hypervisors` hosts | ESXi host(s) reachable over SSH; the one hosting the VM is selected automatically. |
| `target_esxi_host` | Optional: force a specific `hypervisors` member instead of auto-detection. |
| `fail_on_snapshots` / `allow_skipped_disks` | Stage 1 safety switches (defaults: stop). |
| `xcopy_required` / `xcopy_min_throughput_mib` | Stage 1 offload checks (default: stop when offload is impossible; no throughput warning). |
| `mapping_output_dir` | Where stage 1 writes the stage 2 mapping fragment (`generated/`). |
| `cinder_pure_host` / `cinder_pure_volume_type` | Stage 2: Cinder backend (`host@backend#pool`) and volume type of the Pure backend. |
| `default_boot_image_properties` | Stage 2: image properties applied to every boot volume under the disk's own. |

> ⚠️ Secrets (vCenter/ESXi passwords, FlashArray API token) belong in `vault.yml` encrypted with
> **Ansible Vault** — never commit them in plaintext. `vault.yml` is git-ignored; only the
> `vault.example.yml` template is tracked. Rotate any credential that has ever been committed.

## Usage

Development and execution happen on a Linux host using **Docker**, so you don't need to install
Ansible or its collections directly. The inventory path comes from `ansible.cfg`, so no `-i` is
needed.

**1. Build the Ansible image**

```bash
docker build -t vsphere-os-migration .
```

**2. Stage 1 dry run** (safe — inspects vCenter, the FlashArray and the ESXi host read-only, prints
the plan and writes `generated/mapping-<vm>.yaml`, changes nothing):

```bash
docker run --rm -it \
  -v "$PWD":/work -w /work \
  vsphere-os-migration \
  ansible-playbook migrate_vm.yaml --ask-vault-pass
```

**3. Stage 1 execute** (VM must be powered off):

```bash
docker run --rm -it \
  -v "$PWD":/work -w /work \
  vsphere-os-migration \
  ansible-playbook migrate_vm.yaml --ask-vault-pass -e "dry_run=false"
```

**4. Review the mapping.** Open `generated/mapping-<vm>.yaml`, replace the vSphere portgroup names
with Neutron networks, check flavor, key pair, security groups and the boot disk's
`image_properties`, then merge it into `mapping.yaml` (several VMs) or use it directly.

**5. Stage 2 dry run** (validates the mapping against OpenStack: flavor, networks, volumes managed
or manageable). OpenStack credentials have to reach the container; the simplest way is an
`admin-openrc.sh` exported into the environment:

```bash
set -a; source admin-openrc.sh; set +a
docker run --rm -it \
  -v "$PWD":/work -w /work \
  -e OS_AUTH_URL -e OS_USERNAME -e OS_PASSWORD -e OS_PROJECT_NAME \
  -e OS_USER_DOMAIN_NAME -e OS_PROJECT_DOMAIN_NAME -e OS_REGION_NAME -e OS_INTERFACE \
  -e OS_IDENTITY_API_VERSION \
  vsphere-os-migration \
  ansible-playbook migrate_to_openstack.yaml -e mapping_file=generated/mapping-<vm>.yaml
```

(Or mount a `clouds.yaml` and pass `-e OS_CLOUD=<name>`.)

**6. Stage 2 execute:**

```bash
docker run --rm -it ... vsphere-os-migration \
  ansible-playbook migrate_to_openstack.yaml -e mapping_file=generated/mapping-<vm>.yaml -e "dry_run=false"
```

`site.yml` runs both stages back to back once `mapping.yaml` exists. The same `ansible-playbook`
commands work directly on a control node that has the collections from `requirements.yml` and the
packages from `requirements.txt` installed.

## Safety & security notes

- **Cold migration only.** The playbook refuses to run against a powered-on VM (outside dry-run) to
  avoid copying a disk with in-flight writes. A VM with snapshots stops the run by default: the clone
  would carry the current state of each snapshot chain but not the snapshots themselves.
- **Nothing is skipped silently.** Disks that are not flat VMDKs stop the run unless
  `allow_skipped_disks` is set, and are listed either way. A clone that cannot be offloaded stops the
  run unless `xcopy_required: false`.
- **Secrets belong in Ansible Vault.** Put credentials in `vault.yml` (`ansible-vault encrypt`);
  it is git-ignored. Rotate any credential that has ever been pushed to git: early history of this
  repository contained a plaintext inventory, and those values should be treated as burned.
- **Idempotency / re-runs.** Stage 1 wraps execution in `block`/`rescue`/`always`, so the temp RDM
  removal and volume disconnect run even on failure, and the failure message names the task and
  error. Re-running stage 1 for the same VM reuses (and overwrites) volumes of the same name that
  stage 2 has not yet managed. Stage 2 is idempotent: re-running it for migrated VMs changes nothing
  (already-managed volumes are skipped, image properties are only written when they differ and the
  volume is not yet attached).
- **`validate_certs: false`** is the default for vCenter and the FlashArray REST API — acceptable in
  labs, but enable certificate validation for production (`vcenter_validate_certs: true`,
  `fa_validate_certs: true`). `host_key_checking` is off for the ESXi SSH connection for the same
  reason.

## Limitations & known issues

- **Partly lab-tested.** The XCOPY prerequisite checks and the generated mapping have been dry-run
  against a lab vCenter and FlashArray. The VAAI device status check and the clone throughput
  report run only on a real clone and have not been exercised yet.
- **One VM per stage 1 run.** Stage 2 takes a multi-VM mapping; stage 1 is invoked once per VM.
- **ESXi host must be in the inventory** — stage 1 runs `vmkfstools` on the host vCenter reports for
  the VM, so that host has to be listed in the `hypervisors` group (the run stops with a clear
  message otherwise). `target_esxi_host` forces a specific host.
- **Only "flat" VMDKs** (`FlatVer2` backing) are processed; RDMs and other backing types are
  reported and, by default, stop the run. The disks of a VM with snapshots still report `FlatVer2`
  and clone the current state of the chain.
- **Volume names.** VM names are folded to FlashArray-safe names (`Web Server 01` →
  `web-server-01`); two VMs that fold to the same name would share volume names.
- **UEFI boot entries are not migrated.** vSphere keeps them in the VM's `.nvram` file, so the
  instance starts with empty firmware variables and boots only if the guest has the fallback loader
  `\EFI\BOOT\BOOTX64.EFI` on its EFI partition (Windows and most current Linux distributions do).
  Virtual TPM contents are not migrated either.
- **Guest drivers.** The generated mapping presents virtio-scsi, which needs virtio drivers in the
  guest's initramfs; a RHEL-family guest installed on VMware typically has none and stops in the
  dracut emergency shell. Without changing the guest, use `hw_disk_bus: sata` (when the VM has an
  AHCI controller) and `hw_vif_model: vmxnet3`. VMware PVSCSI (`hw_scsi_model: vmpvscsi`) is
  accepted by Nova but OVMF cannot boot from it, and q35 (UEFI) has no IDE bus.
- **Guest-side adjustments** after boot-from-volume are out of scope: installing virtio drivers,
  cloud-init (which treats the migrated guest as a new instance), removal of VMware Tools, and
  network configuration updated for the new interface names.
- **Offload is checked, not proven.** The prerequisite checks establish that ESXi *may* offload the
  clone; the throughput report is a heuristic. The esxtop VAAI counters are the authoritative proof.

## Roadmap

- [x] Detect the correct ESXi host automatically (from the VM's placement).
- [x] Match the FlashArray host object by initiator, create it if absent.
- [x] Snapshot and skipped-disk checks; XCOPY prerequisite checks.
- [x] Generate the stage 2 mapping from stage 1; image properties for UEFI/virtio.
- [x] `ansible-lint` / `yamllint` in CI; pinned collections and Python packages.
- [ ] Exercise the new checks against hardware; read the esxtop VAAI counters around the clone.
- [ ] Multi-VM stage 1 (loop over a VM list, one mapping file out).
- [ ] Optional post-boot guest remediation (virtio/cloud-init) helpers.
- [ ] A license.

## Repository layout

```
.
├── README.md                 # This file
├── ansible.cfg               # inventory path, roles_path, sane defaults
├── Dockerfile                # Migration-runner image (ansible + collections/SDKs)
├── requirements.txt          # Python packages for the image (pinned)
├── requirements.yml          # Ansible collections (everpure.flasharray, vmware, openstack.cloud)
├── site.yml                  # Full pipeline (stage 1 + stage 2)
├── migrate_vm.yaml           # Stage 1 entry playbook  -> role vsphere_to_pure
├── migrate_to_openstack.yaml # Stage 2 entry playbook  -> role pure_to_openstack
├── mapping.example.yaml      # vSphere → OpenStack mapping (copy to mapping.yaml)
├── generated/                # mapping-<vm>.yaml written by stage 1 (git-ignored)
│
├── .github/workflows/lint.yml  # yamllint, ansible-lint, playbook syntax check
├── .ansible-lint / .yamllint
│
├── inventory/
│   ├── hosts.yml             # hosts/groups only (localhost + ESXi hypervisors)
│   └── group_vars/all/
│       ├── main.yml          # shared non-secret config (vCenter/Pure/OpenStack)
│       └── vault.example.yml # secrets template → copy to vault.yml + ansible-vault encrypt
│
├── roles/
│   ├── vsphere_to_pure/      # Stage 1: VMDK → Pure volume via XCOPY (block/always cleanup)
│   │   ├── defaults/main.yml
│   │   ├── tasks/{main,resolve_esxi_host,resolve_pure_host,check_xcopy,migrate_disk,write_mapping}.yml
│   │   └── README.md
│   └── pure_to_openstack/    # Stage 2: cinder manage-existing → Nova boot-from-volume
│       ├── defaults/main.yml
│       ├── tasks/{main,validate_vm,import_vm}.yml
│       └── README.md
│
└── openstack-lab/            # Reproducible kolla-ansible OpenStack 2026.1 dev lab
```

## Disclaimer

This project performs storage- and hypervisor-level operations that create volumes, present devices
to ESXi, and clone disk data. **Always run in dry-run mode first**, test against non-production VMs,
and ensure you have working backups before migrating anything you care about. Provided as-is, without
warranty.
