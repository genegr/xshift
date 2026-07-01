# vSphere to OpenStack VM Migration (Pure FlashArray XCOPY)

Fast, storage-offloaded cold migration of virtual machine disks from **VMware vSphere** to
**OpenStack**, using **Pure Storage FlashArray** VAAI **XCOPY** to move the data at array speed
instead of copying it over the network.

Instead of streaming each VMDK across the wire (slow, network-bound), this project asks the
FlashArray to duplicate the blocks internally. A multi-hundred-GB disk that would take hours over
NFS/iSCSI copy is reduced to minutes (or seconds on thin/deduplicated data).

> **Status:** the vSphere → FlashArray data-landing stage is implemented and works today. The
> OpenStack import stage (Cinder *manage existing* + Nova *boot-from-volume*) is designed below and
> on the [roadmap](#roadmap) but not yet automated in this repo. See
> [What works today vs. what's planned](#what-works-today-vs-whats-planned).

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
| Cinder *manage existing* import of the landed volume | ⏳ Planned |
| Nova boot-from-volume instance creation | ⏳ Planned |
| Declarative vSphere→OpenStack VM mapping (flavor/network/disks) | ⏳ Planned |
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

All configuration currently lives in [`inventory.yaml`](inventory.yaml). Edit it to match your
environment:

| Variable | Description |
|----------|-------------|
| `dry_run` | `true` (default) plans without making changes. Override with `-e "dry_run=false"` to execute. |
| `vcenter_hostname` / `vcenter_username` / `vcenter_password` | vCenter connection details. |
| `vcenter_datacenter` | Datacenter containing the target VM. |
| `target_vm_name` | The VM to migrate. |
| `fa_url` / `fa_api_token` | FlashArray management endpoint and API token. |
| `pure_host_name` | FlashArray host/host-group object representing the ESXi host. |
| `hypervisors` hosts | ESXi host(s) reachable over SSH for `vmkfstools`. |

> ⚠️ Secrets are currently stored in plaintext in `inventory.yaml`. **Do not commit real
> credentials.** Move them to **Ansible Vault** or environment variables before using this in any
> real environment, and rotate any token that has been committed. See
> [Safety & security notes](#safety--security-notes).

## Usage

Development and execution happen on a Linux host using **Docker**, so you don't need to install
Ansible or its collections directly. (See [`CLAUDE.md`](CLAUDE.md) for the dev workflow.)

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
- **Secrets must not be committed.** The sample `inventory.yaml` contains placeholder credentials.
  Real deployments should use Ansible Vault (`ansible-vault encrypt`) or inject secrets via
  environment/CI. Rotate any credential that has ever been pushed to git.
- **Idempotency / re-runs.** Re-running after a partial failure may leave a stale temp RDM file or a
  still-attached volume; check for leftovers before retrying (hardening is on the roadmap).
- **`validate_certs: no`** is used for vCenter — acceptable in labs, but enable certificate
  validation for production.

## Limitations & known issues

- **OpenStack import is not automated yet** — the pipeline stops after the data lands on the
  FlashArray volume (steps 6–7 are planned).
- **ESXi host selection is naive** — the playbook uses the first host in the `hypervisors` group
  rather than the host that actually owns the VM / mounts the datastore.
- **Only "flat" VMDKs** (`FlatVer2` backing) are processed; RDMs, snapshots and other backing types
  are skipped.
- **No block/rescue error handling** — a mid-flight failure won't automatically roll back the
  FlashArray connection or remove temp files.
- **Environment-specific paths** (e.g. a hardcoded `ansible_python_interpreter`) will need adjusting.

## Roadmap

- [ ] Automate the OpenStack stage: Cinder *manage existing* + Nova boot-from-volume.
- [ ] Declarative per-VM **mapping** (flavor, networks/ports, per-disk volume + boot device, metadata).
- [ ] Restructure into a proper Ansible **role** with `defaults`, `vars`, and `requirements.yml`.
- [ ] Move secrets to **Ansible Vault**; remove plaintext credentials.
- [ ] Add a **Dockerfile** and pinned dependency manifests for reproducible runs.
- [ ] Detect the correct ESXi host automatically; add block/rescue rollback and idempotent re-runs.
- [ ] Add `ansible-lint` / `yamllint` in CI.

## Repository layout

```
.
├── README.md                 # This file
├── CLAUDE.md                 # Project + dev-workflow notes for AI-assisted development
├── inventory.yaml            # Inventory + configuration (secrets should move to Vault)
├── migrate_vm.yaml           # Entry playbook: read VM, safety checks, loop over disks
└── migrate_disk_tasks.yaml   # Per-disk logic: provision, present, XCOPY clone, cleanup
```

## Disclaimer

This project performs storage- and hypervisor-level operations that create volumes, present devices
to ESXi, and clone disk data. **Always run in dry-run mode first**, test against non-production VMs,
and ensure you have working backups before migrating anything you care about. Provided as-is, without
warranty.
