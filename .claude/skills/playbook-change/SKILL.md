---
name: playbook-change
description: Checklist for changing xshift's Ansible - adding, removing or reordering tasks in roles/vsphere_to_pure or roles/pure_to_openstack, adding a module call, a variable or a safety check. Covers dry-run semantics, the facts shared between task files, naming, the always-cleanup rule, ansible-core 2.21 strictness, docs to update and how to keep the logic testable offline. Use before editing any task file, defaults or inventory.
---

# Changing the roles

## Before you write the task

1. **Where does it belong?** A read-only check goes early in `main.yml` (stage 1) or in `validate_vm.yml` (stage 2), before anything is created, and runs on dry runs. A mutation goes inside the `when: not (dry_run | bool)` block of `migrate_disk.yml` / in `import_vm.yml`.
2. **Dry runs.** A dry run must change nothing but may read everything: vCenter, the ESXi host's API (`vmware_vmdk_info`), the FlashArray REST API, OpenStack. If the new task needs a credential the dry run did not need before, say so in the README.
3. **Which module?** Prefer an Ansible module to `command`/`shell`. For the OpenStack CLI calls that already use `command` (`openstack volume create --remote-source` has no module), keep `changed_when`/`failed_when` explicit and quote with `| quote`. For ESXi: no SSH, no `delegate_to` an ESXi host - read skill `esxi-disk-clone`.

## The shared facts

Stage 1 is a chain of task files that pass facts to each other:

| Set by | Facts | Read by |
|--------|-------|---------|
| `main.yml` | `vm_general_info`, `vm_flat_disks`, `vm_skipped_disks`, `vm_name_slug` | everything after it, `write_mapping.yml` |
| `resolve_esxi_host.yml` | `esxi_exec_host`, `esxi_exec_api_host`, `esxi_exec_vcenter_name`, `esxi_pure_host_override`, `esxi_on_placement` | `resolve_pure_host.yml`, `migrate_disk.yml`, `main.yml` |
| `resolve_pure_host.yml` | `esxi_hba_facts`, `esxi_advanced_options`, `esxi_exec_pure_host`, `pure_host_to_create` | `check_xcopy.yml`, `migrate_disk.yml` |
| `check_xcopy.yml` | `source_datastores`, `source_datastore_names`, `source_pure_devices`, `xcopy_problems` | `migrate_disk.yml` (dry-run plan) |

Rename or drop one and grep for every reader, then update `tests/logic/test.yml` and `.claude/skills/verify-changes/mock/play.yml`, which inject these facts. Stage 2 reads `vm_migrations` from the mapping file; the stage 1 fragment writer (`render_mapping.yml`) and `mapping.example.yaml` define its shape together with `validate_vm.yml`.

## Rules for the task itself

- **Strict booleans.** ansible-core 2.21 rejects a non-boolean `when`/`until`/`failed_when`: `when: (x | default('', true) | length) > 0`, `when: flag | bool`.
- **Passwords.** Never `set_fact` one (the result prints at `-v`). Read `hostvars[...]` inside the module call; vmware modules mask `password`.
- **Cleanup lives in `always`**, and a failing task there skips the ones after it. Steps that must not block the disconnect and rescan use `ignore_errors: true` and a following warning task (see "Remove the temporary RDM files").
- **Names.** `Disk {{ disk_index }} | ...` per-disk, `{{ vm.name }} | ...` per-VM. Keep the prefix on new tasks: it is what makes the output readable.
- **Register what you read.** A value the logic needs offline (a vCenter read, a REST answer) should be read in one task and *evaluated* in another, so `tests/logic` can inject the read result. `check_xcopy.yml` + `resolve_pure_host.yml` and `render_mapping.yml` + `write_mapping.yml` are the two examples.
- **Lint.** `.ansible-lint` profile `moderate`, skips `var-naming[no-role-prefix]` and `name[template]`. yamllint: 140 columns, `true`/`false` only.

## New variables and dependencies

- Put a default in `roles/<role>/defaults/main.yml` with a comment saying what it changes and its unit. Shared per-site values go in `inventory/group_vars/all/main.yml`, secrets in `vault.example.yml` (names only, `CHANGE_ME` values).
- A new collection or Python package: `requirements.yml` / `requirements.txt` with exact pins, then rebuild the image. Check the Dockerfile still has what the installer needs (`git` for a git-pinned collection).
- A new module needs `ansible-core` compatibility: the stage 1 collection requires 2.21 or later.

## Docs and tests that must move with the change

- README.md: the "What is checked before anything is copied" table, "Prerequisites", the configuration table, "Limitations" (state honestly what a lab run has and has not shown).
- `roles/<role>/README.md` and the comments in `defaults/main.yml`.
- `tests/logic/test.yml` for evaluable logic, `verify-changes/mock` for the per-disk flow (skill `verify-changes`).
- If the change affects a lab procedure or a recovery step: `lab-migration`, `migration-recovery`.

## Then

Run skill `verify-changes`. Commit only when asked.
