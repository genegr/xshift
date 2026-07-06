# Role: pure_to_openstack

Stage 2 of the migration. Imports the Pure FlashArray volumes left by stage 1 into **Cinder** via
*manage-existing* (no data copy) and recreates each VM as a **Nova** instance using
**boot-from-volume**, attaching any additional disks as data volumes.

Driven by `vm_migrations` from the mapping file (see `mapping.example.yaml`). OpenStack credentials
come from the environment (`source admin-openrc.sh`) or `OS_CLOUD`.

## Flow (per VM)
1. `cinder manage` each Pure volume into Cinder (idempotent; skips if already managed).
2. Wait until all volumes are `available`.
3. Boot the instance from the `boot: true` volume (`openstack.cloud.server` `boot_volume`).
4. Attach the remaining volumes (`openstack.cloud.server_volume`).

## Key variables

| Variable | Purpose |
|----------|---------|
| `dry_run` | `true` prints the plan; `-e dry_run=false` executes |
| `cinder_pure_host` | Cinder backend host `host@backend#pool` for manage-existing |
| `cinder_pure_volume_type` | Volume type mapped to the Pure backend |
| `vm_migrations` | Per-VM mapping (from the mapping file) |

## Requirements
`openstacksdk`, `python-openstackclient`, `python-cinderclient`, and the `openstack.cloud`
collection (all in the runner image / `requirements.yml`). `cinder manage` uses the `cinder` CLI
because OpenStackClient has no manage-existing command.
