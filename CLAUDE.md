# CLAUDE.md

xshift cold-migrates powered-off vSphere VMs to OpenStack. One Pure FlashArray holds both the VMware datastore and the OpenStack volumes, so ESXi offloads the disk copy to the array (VAAI XCOPY) and Cinder then *manages* the resulting volume in place. There is no second data copy.

Two stages. Run them separately the first time, and review `generated/mapping-<vm>.yaml` in between:
- **Stage 1**, `migrate_vm.yaml` -> role `vsphere_to_pure`. Per flat VMDK: create a FlashArray volume, present it to the VM's ESXi host, clone the VMDK onto it as a physical RDM, remove the RDM, disconnect the volume. Then write a mapping fragment.
- **Stage 2**, `migrate_to_openstack.yaml` -> role `pure_to_openstack`. Validate the mapping, Cinder manage-existing, set image properties, boot from volume, attach data volumes.

`site.yml` chains both. README.md has the full flow, prerequisites and limitations; the role READMEs hold the per-role detail.

## Layout

- `roles/vsphere_to_pure/tasks/`
  - `main.yml` is the stage 1 flow.
  - `resolve_esxi_host.yml`, `resolve_pure_host.yml` pick the ESXi host and the FlashArray host object.
  - `check_xcopy.yml` evaluates the offload prerequisites, from facts that `resolve_pure_host.yml` read.
  - `migrate_disk.yml` is the per-disk create, present, clone, clean-up flow.
  - `write_mapping.yml` reads vCenter; `render_mapping.yml` renders the mapping and is testable offline.
- `roles/pure_to_openstack/tasks/`: `validate_vm.yml` (read-only checks, also on dry runs), `import_vm.yml`.
- `inventory/`: `hosts.yml` has hosts only (`hypervisors` carries the ESXi root login); shared config is in `group_vars/all/main.yml`; secrets go in `vault.yml` (git-ignored, template `vault.example.yml`).
- `tests/logic/test.yml` with a fake `openstack` CLI in `tests/logic/bin/`.
- `openstack-lab/`: a reproducible single-node kolla-ansible OpenStack for development.
- `.claude/skills/`: the skills listed at the bottom.

## Commands

Everything runs in the Docker image, which has the exact tool versions (ansible-core 2.21, pinned collections). There is no need to install Ansible on your machine, and `ansible-core` older than 2.21 will not load the collection stage 1 needs.

```bash
docker build -t vsphere-os-migration .
docker run --rm -v "$PWD":/work -w /work vsphere-os-migration bash -c '
  pip install -q ansible-lint yamllint            # CI installs these too; they are not in the image
  cp mapping.example.yaml mapping.yaml            # the syntax check loads the stage 2 mapping
  for p in migrate_vm.yaml migrate_to_openstack.yaml site.yml; do ansible-playbook --syntax-check "$p"; done
  rm mapping.yaml
  ansible-playbook tests/logic/test.yml
  yamllint --strict . && ansible-lint'
```

If `pip` or `ansible-galaxy` cannot resolve names inside the container (typical on a lab Docker host whose default bridge overlaps its network), add `--network host` to both `docker build` and `docker run`.

CI (`.github/workflows/lint.yml`) runs the same. The `verify-changes` skill adds an offline flow test for the per-disk tasks and says how to compare lint against `main`.

## Rules

- **Dry run is the default and must stay read-only.** `dry_run: true` in role defaults and group_vars; `-e dry_run=false` executes. Anything that changes state sits in a block guarded by `when: not (dry_run | bool)`. A dry run still logs in to vCenter, to the ESXi host's API and to the FlashArray REST API (stage 2: to OpenStack), so it needs real credentials. A new read-only check goes before anything is created and runs on dry runs too.
- **ESXi disk work goes through the vSphere API. Stage 1 uses no SSH.** The clone is `community.vmware.vmware_vmdk_clone` and the source check is `vmware_vmdk_info`, both from our module (community.vmware PR #2623), pinned by commit in `requirements.yml`. Do not add `command`/`shell`, `vmkfstools`, `esxcli` or a task delegated to an ESXi host. Skill `esxi-disk-clone` has the reasons.
- **Secrets.** Never commit `vault.yml`, tokens, `clouds.yaml` or `admin-openrc.sh`. Do not copy a password into a fact: `set_fact` echoes it at `-v`. Read it from `hostvars` in the task that needs it. Committed files carry placeholders only (`example.com`, `192.0.2.x`), never lab addresses or names.
- **ansible-core 2.21 is strict.** `when` must be a real boolean: write `(x | length) > 0` and `(flag | bool)`, not a bare string or list.
- **Cleanup must not be blockable.** Execution sits in `block`/`rescue`/`always`. A failing task inside `always` stops the tasks after it, so use `ignore_errors` plus a warning for steps that must not stop the FlashArray disconnect and rescan.
- **Facts cross file boundaries.** `check_xcopy.yml` and `migrate_disk.yml` read what `main.yml` and `resolve_*.yml` set (`vm_flat_disks`, `vm_name_slug`, `esxi_exec_*`, `esxi_hba_facts`, `esxi_advanced_options`, `esxi_exec_pure_host`). `tests/logic` and the `verify-changes` mock inject them, so a rename must update both.
- **Volume naming is a contract between the stages.** Stage 1 names volumes `<vm slug>-disk-<vCenter disk key>`; stage 2 looks them up by that name (mapping `pure_volume`). The slug rule is tested in `tests/logic/test.yml`.
- **Offload is checked, not proven.** The prerequisite checks and the throughput figure say XCOPY *may* have happened. Do not word output or docs as proof; the esxtop VAAI counters are the authority.
- **Shared array.** Only touch FlashArray objects this run created. Do not eradicate volumes (the destroy bin keeps them recoverable). Always give `purefa_host state: absent` a `volume:`; without it the module deletes the host object.
- **Task names** lead with their context (`Disk 0 | Clone ...`, `<vm> | ...`); `.ansible-lint` skips `name[template]` for that reason. Lint profile is `moderate`; yamllint line length is 140.
- **Docs move with behavior.** Update README.md (the "What is checked" table, prerequisites, limitations), the role README and the comments in `defaults/main.yml` in the same change.
- **License.** The repository is Apache-2.0 (`LICENSE`); new files need no license header. Do not paste code from GPL-licensed projects into it: the collections the roles depend on are GPL-licensed (`community.vmware` is GPL-3.0-or-later), so call their modules and never copy their source.
- **Git.** Commit only when asked. Commit subjects are sentence-case imperatives with no type prefix (`Fix stage 1 snapshot check against vCenter`). Do not commit `generated/`, `mapping.yaml`, `.ansible/` or anything from `.claude/settings.local.json` or `CLAUDE.local.md`.
- **Real infrastructure needs a go-ahead.** Do not run `dry_run=false` (it creates and removes FlashArray volumes, RDM files and OpenStack objects) unless the person you work for says to, for that VM, in this session. A dry run is fine without asking.

## Local files

`CLAUDE.local.md` (git-ignored) is for your own lab facts: hostnames, array and vCenter names, where credentials live, the VM you test with, how to reach a Docker host. Skills point there instead of embedding such details.

## Skills

| Skill | Use it when |
|-------|-------------|
| `verify-changes` | before saying a change works: CI checks, lint baseline, offline flow test of `migrate_disk.yml` |
| `playbook-change` | adding, removing or reordering tasks in either role |
| `esxi-disk-clone` | touching anything that talks to an ESXi host, the pinned collection, or the XCOPY checks |
| `openstack-import` | stage 2, the mapping file, image properties, or a guest that does not boot |
| `lab-migration` | running a real migration on a lab to test a change |
| `migration-recovery` | a run failed, or leftovers (volumes, RDM files, Cinder volumes) need cleaning up |
