# Role: pure_to_openstack

Stage 2 of the migration. Imports the Pure FlashArray volumes left by stage 1 into **Cinder** via
*manage-existing* (no data copy), sets the image properties Nova needs to boot them, and recreates
each VM as a **Nova** instance using **boot-from-volume**, attaching any additional disks as data
volumes.

Driven by `vm_migrations` from the mapping file (see `mapping.example.yaml`, or the fragment stage 1
writes to `generated/mapping-<vm>.yaml`). OpenStack credentials come from the environment
(`source admin-openrc.sh`) or `OS_CLOUD`.

## Flow

Every entry is validated first, on dry runs and real runs alike (`validate_vm.yml`):

1. Shape: at least one disk, exactly one `boot: true`, at least one network, `flavor` or
   `flavor_auto` with `vcpus`/`ram_mb`.
2. The flavor and the networks exist.
3. Each volume is already a Cinder volume, or Cinder lists it as manageable on `cinder_pure_host`
   and `safe_to_manage` (`openstack block storage volume manageable list`).

A dry run stops here. A real run then, per VM (`import_vm.yml`):

4. `openstack volume create --remote-source source-name=<vol> --host <cinder_pure_host>` manages
   each Pure volume that is not yet a Cinder volume (idempotent; `--bootable` on the boot disk).
   The Pure driver renames the array volume to `volume-<id>-cinder`; the mapping name stays as the
   Cinder name.
5. Wait until all volumes are `available` (or `in-use` on a re-run); `error`/`error_managing`
   fails at once with the unmanage command to undo.
6. `openstack volume set --image-property` applies `default_boot_image_properties` merged with the
   disk's `image_properties` (`hw_firmware_type`, `hw_disk_bus`, ...), only where they differ and
   only while the volume is unattached. Nova reads them once, at instance creation; a difference on
   an attached volume is reported, and the instance must be deleted (the volume is kept) and the
   run repeated to apply it. Properties removed from the mapping are not unset on the volume.
7. Security group names are resolved to ids in the current project (an admin sees every project's
   `default` group).
8. Boot the instance from the `boot: true` volume (`openstack.cloud.server` `boot_volume`).
9. Attach the remaining volumes (`openstack.cloud.server_volume`).

## Key variables

| Variable | Purpose |
|----------|---------|
| `dry_run` | `true` validates the mapping against OpenStack and prints the plan; `-e dry_run=false` executes |
| `cinder_pure_host` | Cinder backend host `host@backend#pool` for manage-existing (`cinder get-pools`) |
| `cinder_pure_volume_type` | Volume type mapped to the Pure backend |
| `cinder_api_version` | Block Storage microversion for the manageable listing (default `3.8`) |
| `default_boot_image_properties` | Image properties applied to every boot volume under the disk's own |
| `volume_error_states` | Volume states that end the wait with a failure |
| `vm_migrations` | Per-VM mapping (from the mapping file) |

## Requirements
`openstacksdk`, `python-openstackclient` (with `volume create --remote-source`; the Dockerfile pins
a recent release) and the `openstack.cloud` collection (all in the runner image /
`requirements.yml`). The manageable listing and manage-existing need an admin account.
