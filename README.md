# xshift

**Storage-offloaded vSphere → OpenStack VM migration via Pure FlashArray XCOPY.**

Fast, storage-offloaded cold migration of virtual machine disks from **VMware vSphere** to
**OpenStack**, using **Pure Storage FlashArray** VAAI **XCOPY** to move the data at array speed
instead of copying it over the network.

Instead of streaming each VMDK across the wire (slow, network-bound), this project asks the
FlashArray to duplicate the blocks internally. A multi-hundred-GB disk that would take hours over
NFS/iSCSI copy is reduced to minutes (or seconds on thin/deduplicated data).

> **Status:** both stages are implemented. Stage 1 (vSphere → FlashArray, `migrate_vm.yaml`) clones
> each VMDK onto a Pure volume via XCOPY. Stage 2 (`migrate_to_openstack.yaml`) imports those Pure
> volumes into Cinder via *manage-existing* and boots each VM with Nova *boot-from-volume* — validated
> end-to-end against a kolla-ansible OpenStack 2026.1 lab (see [`openstack-lab/`](openstack-lab/)).
> See [What works today vs. what's planned](#what-works-today-vs-whats-planned).

---

## Table of contents

- [How it works](#how-it-works)
- [Architecture](#architecture)
- [The migration pipeline](#the-migration-pipeline)
- [What works today vs. what's planned](#what-works-today-vs-whats-planned)
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
                        | (VM & disk inventory,                     |
                        |  power state, HBA rescan)                 |
                        |                                           |
   +--------------------+----------+     SSH (vmkfstools)   +-------+--------------+
   |  Ansible control node         |---------------------->|      ESXi host       |
   |  (this project, in Docker)    |                       |  (mounts the VMFS     |
   |                               |                       |   datastore + volume) |
   |  community.vmware             |                       +----------+-----------+
   |  purestorage.flasharray       |                                  |
   |  openstack.cloud (planned)    |    REST API                      | VAAI XCOPY
   +---------------+---------------+----------------+                  | (block copy,
                   |                                |                  |  array-internal)
                   | REST API                       v                  v
                   |                     +---------------------------------------+
                   +-------------------->|          Pure FlashArray              |
                                         |   source VMFS datastore <--XCOPY-->   |
                                         |   destination raw volume              |
                                         +--------------------+------------------+
                                                              |
                                    (planned) Cinder manage   |  same volume,
                                              + Nova BFV       v  no re-copy
                                         +---------------------------------------+
                                         |               OpenStack               |
                                         |   Cinder volume  ->  Nova instance    |
                                         +---------------------------------------+
```

**Components**

| Component | Role |
|-----------|------|
| Ansible control node | Orchestrates everything; runs inside Docker (see [Usage](#usage)). |
| vCenter | Source of truth for VM inventory, disk layout, power state; performs HBA rescans. |
| ESXi host | Executes `vmkfstools` over SSH; must mount both the source datastore and the new volume. |
| Pure FlashArray | Provides both the source datastore and the destination volume; performs the XCOPY. |
| OpenStack (Cinder/Nova) | *(planned)* Imports the landed volume and boots the migrated instance. |

## The migration pipeline

```
 vSphere VM (powered off)
        │
        ▼
 [1] Read disk layout from vCenter            ── implemented
        │
        ▼
 [2] Provision matching volume on FlashArray  ── implemented
        │
        ▼
 [3] Present volume to ESXi + rescan          ── implemented
        │
        ▼
 [4] vmkfstools clone → XCOPY block copy      ── implemented
        │
        ▼
 [5] Detach volume + cleanup RDM              ── implemented
        │
        ▼
 [6] Cinder "manage existing" imports volume  ── PLANNED
        │
        ▼
 [7] Nova boot-from-volume creates instance   ── PLANNED
        │
        ▼
 OpenStack instance running on the same data
```

### Planned: mapping vSphere → OpenStack (steps 6–7)

Because the data already sits on a FlashArray volume that OpenStack's Cinder driver also manages,
the import needs **no data movement** — only metadata. The intended mechanism:

- **`cinder manage` / `openstack volume manage`** imports the pre-existing backend volume into Cinder
  by referencing its FlashArray volume name, producing a first-class Cinder volume.
- **Nova boot-from-volume** then launches an instance whose root disk *is* that Cinder volume.

To make this repeatable, the migration will be driven by a per-VM **mapping** that translates
vSphere concepts into OpenStack concepts (flavor from CPU/RAM, portgroup → Neutron network, each
VMDK → a Cinder volume with a boot flag, etc.). The mapping design will land with the roadmap work.

## What works today vs. what's planned

| Stage | Status |
|-------|--------|
| Read VM power state and disk inventory from vCenter | ✅ Implemented |
| Cold-migration safety check (VM must be powered off) | ✅ Implemented |
| Provision destination volumes on FlashArray | ✅ Implemented |
| Present volume to ESXi, rescan, XCOPY clone via `vmkfstools` | ✅ Implemented |
| Cleanup (remove RDM, detach volume, final rescan) | ✅ Implemented |
| Dry-run mode (plan without changing anything) | ✅ Implemented |
| Cinder *manage existing* import of the landed volume | ✅ Implemented (`migrate_to_openstack.yaml`) |
| Nova boot-from-volume instance creation | ✅ Implemented (`openstack_import_tasks.yaml`) |
| Declarative vSphere→OpenStack VM mapping (flavor/network/disks) | ✅ Implemented (`mapping.example.yaml`) |
| Reproducible OpenStack dev lab (kolla-ansible AIO + Pure iSCSI) | ✅ Implemented ([`openstack-lab/`](openstack-lab/)) |
| Ansible Vault for secrets, role-based structure, CI lint | ⏳ Planned |

## Prerequisites

**On the FlashArray / vSphere side**
- The **source VMDK datastore and the destination volume live on the same FlashArray** (this is what
  makes XCOPY offload possible). Cross-array copies still work but fall back to a normal, slower copy.
- VAAI hardware acceleration enabled on the ESXi hosts.
- SSH enabled on the target ESXi host (used to run `vmkfstools`).
- A FlashArray **host or host-group object** already defined for the ESXi host (`pure_host_name`).
- A FlashArray **API token** with volume/host management rights.
- A vCenter account that can read VM inventory and trigger storage rescans.

**On the control node** (all provided by the Docker image — see [Usage](#usage))
- Ansible.
- Collections: `community.vmware`, `purestorage.flasharray`, and (for the planned OpenStack stage)
  `openstack.cloud`.
- Python libraries: `pyvmomi`, `py-pure-client`, and `openstacksdk`.

## Configuration

Shared configuration lives in [`inventory/group_vars/all/main.yml`](inventory/group_vars/all/main.yml);
hosts/groups in [`inventory/hosts.yml`](inventory/hosts.yml); secrets in `vault.yml` (copy from
[`vault.example.yml`](inventory/group_vars/all/vault.example.yml) and `ansible-vault encrypt`).
Per-role tunables are in each role's `defaults/main.yml`. Key variables:

| Variable | Description |
|----------|-------------|
| `dry_run` | `true` (default) plans without making changes. Override with `-e "dry_run=false"` to execute. |
| `vcenter_hostname` / `vcenter_username` / `vcenter_password` | vCenter connection details. |
| `vcenter_datacenter` | Datacenter containing the target VM. |
| `target_vm_name` | The VM to migrate. |
| `fa_url` / `fa_api_token` | FlashArray management endpoint and API token. |
| `pure_host_name` | FlashArray host/host-group object representing the ESXi host. |
| `hypervisors` hosts | ESXi host(s) reachable over SSH for `vmkfstools`. |

> ⚠️ Secrets (vCenter/ESXi passwords, FlashArray API token) belong in `vault.yml` encrypted with
> **Ansible Vault** — never commit them in plaintext. `vault.yml` is git-ignored; only the
> `vault.example.yml` template is tracked. Rotate any credential that has ever been committed.

## Usage

Development and execution happen on a Linux host using **Docker**, so you don't need to install
Ansible or its collections directly.

**1. Build the Ansible image** *(Dockerfile added with the tooling work; see roadmap)*

```bash
docker build -t vsphere-os-migration .
```

**2. Dry run** (safe — inspects vCenter and prints the plan, changes nothing):

```bash
docker run --rm -it \
  -v "$PWD":/work -w /work \
  vsphere-os-migration \
  ansible-playbook -i inventory.yaml migrate_vm.yaml
```

**3. Execute the migration** (VM must be powered off):

```bash
docker run --rm -it \
  -v "$PWD":/work -w /work \
  vsphere-os-migration \
  ansible-playbook -i inventory.yaml migrate_vm.yaml -e "dry_run=false"
```

Until the Dockerfile lands you can run the same `ansible-playbook` commands directly on a control
node that has the collections installed.

## Safety & security notes

- **Cold migration only.** The playbook refuses to run against a powered-on VM (outside dry-run) to
  avoid copying a disk with in-flight writes.
- **Secrets belong in Ansible Vault.** Put credentials in `vault.yml` (`ansible-vault encrypt`);
  it is git-ignored. Rotate any credential that has ever been pushed to git.
- **Idempotency / re-runs.** Stage 1 wraps execution in `block`/`always`, so the temp RDM removal
  and volume disconnect run even on failure. Stage 2's manage step is idempotent (skips
  already-managed volumes).
- **`validate_certs: false`** is the default for vCenter — acceptable in labs, but enable
  certificate validation for production (`vcenter_validate_certs: true`).

## Limitations & known issues

- **ESXi host selection is naive** — stage 1 uses `target_esxi_host` (defaults to the first host in
  the `hypervisors` group) rather than auto-detecting the host that owns the VM / mounts the
  datastore.
- **Only "flat" VMDKs** (`FlatVer2` backing) are processed; RDMs, snapshots and other backing types
  are skipped.
- **Guest-side adjustments** (drivers/initramfs, network config) after boot-from-volume are out of
  scope — a migrated Linux guest may need virtio drivers / cloud-init tweaks to boot cleanly.

## Roadmap

- [ ] Detect the correct ESXi host automatically (from the VM's placement).
- [ ] Add `ansible-lint` / `yamllint` (+ CI).
- [ ] Optional post-boot guest remediation (virtio/cloud-init) helpers.
- [ ] Pin collection versions in `requirements.yml`.

## Repository layout

```
.
├── README.md                 # This file
├── ansible.cfg               # inventory path, roles_path, sane defaults
├── Dockerfile                # Migration-runner image (ansible + collections/SDKs)
├── requirements.yml          # Ansible collections (openstack.cloud, vmware, purestorage)
├── site.yml                  # Full pipeline (stage 1 + stage 2)
├── migrate_vm.yaml           # Stage 1 entry playbook  -> role vsphere_to_pure
├── migrate_to_openstack.yaml # Stage 2 entry playbook  -> role pure_to_openstack
├── mapping.example.yaml      # vSphere → OpenStack mapping (copy to mapping.yaml)
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
│   │   ├── tasks/{main,migrate_disk}.yml
│   │   └── README.md
│   └── pure_to_openstack/    # Stage 2: cinder manage-existing → Nova boot-from-volume
│       ├── defaults/main.yml
│       ├── tasks/{main,import_vm}.yml
│       └── README.md
│
└── openstack-lab/            # Reproducible kolla-ansible OpenStack 2026.1 dev lab
```

## Disclaimer

This project performs storage- and hypervisor-level operations that create volumes, present devices
to ESXi, and clone disk data. **Always run in dry-run mode first**, test against non-production VMs,
and ensure you have working backups before migrating anything you care about. Provided as-is, without
warranty.
