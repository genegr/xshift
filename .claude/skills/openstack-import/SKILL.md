---
name: openstack-import
description: Stage 2 of xshift (roles/pure_to_openstack) - the mapping file, validation rules, Cinder manage-existing of the Pure volumes, image properties for boot-from-volume, boot and attach, and why a migrated guest might not boot (UEFI, virtio drivers, PVSCSI). Includes how to test offline with the fake openstack CLI and against the openstack-lab. Use when editing stage 2, mapping.example.yaml or the generated mapping, or debugging a migrated instance.
---

# Stage 2: Pure volumes to OpenStack

Input is the mapping (`vm_migrations`): `mapping.yaml` (git-ignored, copy of `mapping.example.yaml`) or the fragment stage 1 writes to `generated/mapping-<vm>.yaml`, passed with `-e mapping_file=...`. OpenStack credentials come from the environment (`source admin-openrc.sh`) or `OS_CLOUD`; manage-existing and the manageable listing need an admin account.

## Flow

1. **`validate_vm.yml` (read-only, runs on dry runs too).** The entry needs a name, at least one disk, exactly one `boot: true`, at least one network, and `flavor` or `flavor_auto` with `vcpus`/`ram_mb`. The flavor and networks must exist. Each volume must already be a Cinder volume, or Cinder must list it as manageable on `cinder_pure_host` and `safe_to_manage`. All problems are collected, then the run stops.
2. **Manage** each Pure volume not yet in Cinder: `openstack volume create --remote-source source-name=<volume> --host <cinder_pure_host> --type <cinder_pure_volume_type>` (`--bootable` for the boot disk). Idempotent: a Cinder volume with that name is skipped.
3. Wait for `available` (or `in-use` on a re-run). `error`/`error_managing` fails at once.
4. **Image properties** (`default_boot_image_properties` merged under the disk's `image_properties`) via `openstack volume set --image-property`, only where they differ and only while the volume is unattached.
5. Security group names resolve to ids in the current project, then boot from the `boot: true` volume (`terminate_volume: false`) and attach the rest.

## Things that are not obvious

- **Names tie the stages together.** `pure_volume` must equal the stage 1 name `<vm slug>-disk-<vCenter disk key>`. After manage, the Pure Cinder driver renames the array volume to `volume-<id>-cinder`; the mapping name stays as the Cinder name.
- **The manageable listing takes the host as a positional argument** (`openstack block storage volume manageable list <host>`), not `--host`, and needs `cinder_api_version` 3.8 or later. `tests/logic/bin/openstack` rejects `--host` on that command on purpose.
- **Image properties are read once**, when Nova creates the instance. A difference on an attached volume is only reported: delete the instance (the volume is kept) and re-run. Properties removed from the mapping are not unset on the volume.
- **Unmanaging** a volume that ended in an error state: `openstack volume delete --remote <name>` returns it to the array untouched. Never delete the array object by hand.
- **Security groups by id**: an admin token sees every project's `default`, so the bare name is ambiguous to Nova.

## Guests that boot badly

- **UEFI.** A UEFI VM booted with the BIOS default never finds its loader. Stage 1 reads `config.firmware` and writes `hw_firmware_type`, plus `hw_machine_type: q35` and `os_secure_boot: required` when Secure Boot is on. UEFI boot entries live in the VM's `.nvram` and are not migrated; the guest needs the fallback loader `\EFI\BOOT\BOOTX64.EFI`.
- **virtio.** The fragment presents `virtio-scsi`, which needs virtio drivers in the guest's initramfs. A RHEL-family guest installed on VMware typically has none and stops in dracut. Without changing the guest: `hw_disk_bus: sata` (when the VM has an AHCI controller) and `hw_vif_model: vmxnet3`.
- **PVSCSI** (`hw_scsi_model: vmpvscsi`) is accepted by Nova but OVMF cannot boot from it; q35 (UEFI) has no IDE bus.
- Guest-side work after the boot (virtio drivers, cloud-init, VMware Tools removal, network renaming) is out of scope.

## Testing

- **Offline:** `tests/logic/test.yml` drives `validate_vm.yml` with the fake `openstack` CLI, shaped by `FAKE_MISSING_FLAVOR`, `FAKE_MISSING_NETWORK`, `FAKE_UNMANAGED`, `FAKE_MANAGEABLE_JSON`. Add a case there for every new validation rule; keep the fake as strict as the real CLI.
- **Real:** `openstack-lab/` builds a single-node kolla-ansible OpenStack with a Pure iSCSI Cinder backend (addresses in its README are placeholders). See skill `lab-migration`. Stage 2 was validated end to end there before this skill was written.
- Stage 2 changes are rarely visible in a dry run; the interesting failures (manage errors, boot failures, image property timing) only appear in a real run, so say in the PR whether one happened.
