---
name: verify-changes
description: Verify an xshift change before calling it done - run the same checks as CI (syntax check of all three playbooks, tests/logic, yamllint --strict, ansible-lint) in the Docker image, tell new lint findings from pre-existing ones by linting main, and run the offline mock flow test of roles/vsphere_to_pure/tasks/migrate_disk.yml. Use after any change to a role, inventory, requirements, the Dockerfile or the tests, and before opening a PR.
---

# Verifying a change

Nothing here touches real infrastructure. Run it in the Docker image: it has the right ansible-core (2.21) and collections, and a Windows or macOS workstation usually has no Ansible. On a remote Docker host, copy the tree there first and strip CRs if it came from a Windows checkout (`.gitattributes` forces LF in new checkouts).

## 1. The CI checks

```bash
docker build -t vsphere-os-migration .
docker run --rm -v "$PWD":/work -w /work vsphere-os-migration bash -c '
  pip install -q ansible-lint yamllint
  cp mapping.example.yaml mapping.yaml
  for p in migrate_vm.yaml migrate_to_openstack.yaml site.yml; do ansible-playbook --syntax-check "$p"; done
  rm mapping.yaml
  ansible-playbook tests/logic/test.yml
  yamllint --strict . && ansible-lint'
```

- **No DNS in the container** (`Temporary failure in name resolution` from `pip` or `ansible-galaxy`, which then shows up as `yamllint: command not found` or a failed build): the Docker host's default bridge overlaps its network. Add `--network host` to `docker build` and every `docker run`.
- A rebuild is needed after any change to `requirements.yml`, `requirements.txt` or the Dockerfile. The collections come from `requirements.yml`, including the pinned community.vmware commit, so a bad pin shows up as a build failure.
- `--syntax-check` does not read `roles/*/tasks/*.yml` that are loaded with `include_tasks`. `tests/logic` and the mock below are what exercise them.
- Run in a copy, or delete `.ansible/` afterwards: ansible-lint installs the collections there (it is git-ignored).

## 2. Is a lint finding yours?

`main` may already carry findings. Compare, do not guess:

```bash
git worktree add /tmp/xshift-base main      # or: git archive main | tar -x -C /tmp/xshift-base
# run ansible-lint -p and yamllint in both trees, then diff the output with line numbers removed
```

Only findings that appear in your tree and not in the baseline are yours. At the time this skill was written both trees passed `ansible-lint` (profile moderate, 0 failures) and `yamllint --strict`. One pre-existing deprecation warning is expected: `vmware_guest_snapshot_info` (removed in community.vmware 8.0.0).

## 3. Offline flow test of the per-disk tasks

`tests/logic` cannot run `migrate_disk.yml`: it calls vCenter, the ESXi host and the FlashArray. `mock/` runs the real task file against stub modules that record their arguments and return canned data, and asserts the flow:

```bash
docker run --rm -v "$PWD":/src:ro vsphere-os-migration bash /src/.claude/skills/verify-changes/mock/run.sh
```

| Scenario | What it proves |
|----------|----------------|
| A happy path | the clone logs in to the ESXi host (`ansible_host`, `ansible_user`, `ansible_password` from the inventory), with `disk_format: rdmp`, the new LUN, `force`, the timeout; the device wait polls until the LUN shows up; both RDM files are removed |
| B clone fails | the run fails naming the task and the cause, and the always section still removes the files, disconnects the volume and rescans |
| C file delete fails | one warning per file, the run goes on, disconnect and rescan still happen |
| D device not accelerated | with `xcopy_required: true` the run stops before the clone |

When it fails, the scenario prints what was expected and the tail of the playbook output. `mock/play.yml` sets the variables that `main.yml` and `resolve_*.yml` normally provide, so a renamed variable fails here first. If you change the intended behavior of `migrate_disk.yml`, update `assert_flow.py` in the same commit. To cover a new module call, add its name to the loops in `run.sh` and its canned answer to `template.py`.

## 4. What these checks cannot show

- Whether a real ESXi host accepts the clone, whether the array offloads it, and what `vStorageSupport` reads for a FlashArray LUN. Only a lab run shows that: skill `lab-migration`.
- Say so in the PR: list which of the sections above you ran, and whether a live run happened.
