#!/bin/bash
# Offline flow test of roles/vsphere_to_pure/tasks/migrate_disk.yml against stub modules.
# From the repo root, on any Docker host (the image has ansible-core 2.21 and nothing else is needed):
#   docker build -t vsphere-os-migration .
#   docker run --rm -v "$PWD":/src:ro vsphere-os-migration bash /src/.claude/skills/verify-changes/mock/run.sh
# Exit code 0 only when every scenario passes. Nothing here contacts vCenter, ESXi or a FlashArray.
set -u
SRC=${SRC:-/src}
MOCK=$SRC/.claude/skills/verify-changes/mock

# Stub collections go first on the path, so they replace the real modules of the same name.
S=/stub/ansible_collections
mk() {  # $1 = namespace/collection, $2 = module
  mkdir -p "$S/$1/plugins/modules"
  sed "s/__NAME__/$2/" "$MOCK/template.py" > "$S/$1/plugins/modules/$2.py"
}
for m in vmware_vmdk_clone vmware_host_scanhba vmware_host_scsidisk_info vsphere_file; do mk community/vmware "$m"; done
for m in purefa_volume purefa_host; do mk everpure/flasharray "$m"; done
export ANSIBLE_COLLECTIONS_PATH=/stub

rm -rf /work && mkdir /work && cp -r "$SRC"/. /work/ && cd /work || exit 1
cp "$MOCK/play.yml" mock_play.yml
failed=0

scenario() {  # $1 = name, $2 = title, rest = env assignments for the stubs
  local name="$1" title="$2"; shift 2
  rm -f /tmp/calls.jsonl /tmp/lun_counter
  env "$@" ansible-playbook -i "$MOCK/inventory.yml" mock_play.yml -e dry_run=false > /tmp/out.txt 2>&1
  local rc=$?
  echo "$name | $title (playbook rc=$rc)"
  python3 "$MOCK/assert_flow.py" "$name" "$rc" || { failed=1; sed 's/^/      | /' /tmp/out.txt | tail -30; }
}

scenario A "happy path" X=1
scenario B "clone fails: rescue reports, always still cleans up" FAIL_CLONE=1
scenario C "RDM file delete fails: warn, still disconnect and rescan" FAIL_DELETE=1
scenario D "device not hardware accelerated: stop before the clone" VSTORAGE=vStorageUnsupported
exit $failed
