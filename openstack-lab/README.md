# openstack-lab — single-node OpenStack for migration development

A reproducible **all-in-one OpenStack 2026.1** (deployed with **kolla-ansible 22.0.0**) used as the
development target for the migration playbooks. It provides Keystone/Glance/Nova/Neutron/**Cinder
with a Pure FlashArray iSCSI backend**, which is what the OpenStack stage of the migration imports
volumes into and boots instances from.

## Topology

```
  dev / jump box (10.225.113.197, has Docker)          openstack00 (172.17.20.101, Ubuntu 24.04)
  ┌───────────────────────────────────────┐           ┌────────────────────────────────────────┐
  │ kolla-deployer:2026.1 container        │  SSH      │ OpenStack 2026.1 (kolla containers)      │
  │  + Docker volume 'kolla-config'        │──────────▶│  ens34  = mgmt/API (host IP)             │
  │  (globals, inventory, passwords, key)  │  ansible  │  ens192 = neutron provider (no IP)       │
  │  kolla.sh / osc.sh wrappers            │           │  local registry :4000 (custom images)   │
  └───────────────────────────────────────┘           │  cinder: LVM(loopback) + Pure iSCSI      │
                                                       └───────────────┬────────────────────────┘
                                                          Pure FlashArray 10.225.112.90 (iSCSI)
```

- **Deployer is containerized** on the jump box; nothing kolla-related is installed on a host's
  system Python. All config/state lives in the `kolla-config` Docker volume.
- Containers run with `--network host` (the jump box `docker0` is `172.17.0.0/16`, which would
  otherwise shadow openstack00's `172.17.20.0/24`).

## Files

| File | Purpose |
|------|---------|
| `Dockerfile.deployer` | kolla-ansible 22.0.0 + openstackclient deployer image |
| `cinder-pure.Dockerfile` | derived cinder-volume image adding `py-pure-client` (Pure driver dep) |
| `globals.overrides.yml` | settings appended to kolla's sample `globals.yml` |
| `config/cinder.conf` | kolla config override → `default_volume_type = pure` |
| `inventory` | all-in-one inventory retargeted to openstack00 over SSH |
| `cinder-loop.service` | systemd unit: recreate the loopback `cinder-volumes` VG on boot |
| `kolla.sh` / `osc.sh` | wrappers to run kolla-ansible / the OpenStack CLI |
| `setup.sh` | end-to-end runbook that reproduces the whole deployment |

## Day-to-day use

```bash
./kolla.sh deploy            # or: reconfigure, prechecks, post-deploy, destroy ...
./osc.sh service list
./osc.sh volume service list # confirm cinder-volume@Pure-FlashArray-iscsi is up
```

Horizon: `http://172.17.20.101/` (user `admin`; password = `OS_PASSWORD` in the volume's
`admin-openrc.sh`).

## Design decisions & workarounds (why this differs from a vanilla AIO)

1. **No-HA topology.** Default kolla puts keepalived+haproxy+**proxysql** in front of a VIP. On a
   single VM, proxysql's admin socket failed kolla's own VRRP health-check (racy `socat "show info"`
   → "oversized first packet"), so keepalived never held the VIP. HA is pointless on one node, so:
   `enable_haproxy: no`, `enable_proxysql: no`, and `kolla_internal_vip_address` = the host IP.
2. **Pure driver needs `py-pure-client`**, absent from the stock cinder image. We build a thin
   derived image (`cinder-pure.Dockerfile`), serve it from a local registry on openstack00
   (`localhost:4000`), and point kolla at it via `cinder_volume_image_full`.
3. **Host services freed on openstack00**: stock `nginx` (held :80, blocked Horizon) and host
   `multipathd`/`multipathd.socket` (held the multipath socket, blocked kolla's multipathd
   container) are disabled — kolla runs its own.
4. **Test images**: `kolla_test_images: yes` (quay.io/openstack.kolla images are gated as test-only
   in 2026.1).
5. **Cinder LVM** uses a 60 GB loopback VG (`cinder-loop.service` makes it survive reboots), kept
   alongside the Pure backend for quick local tests. `pure` is the default volume type.

## Secrets (never committed)

Live only in the `kolla-config` Docker volume, not in git:
`passwords.yml` (incl. `pure_api_token`), the SSH private key, and `admin-openrc.sh`.

## ⚠️ Shared array

`10.225.112.90` is a **shared/production FlashArray**. Cinder only manages its own `*-cinder`
volumes; `pure_eradicate_on_delete` is left at its default (false) so deletes are recoverable from
the array's destroy bin. Do not eradicate volumes you did not create.
