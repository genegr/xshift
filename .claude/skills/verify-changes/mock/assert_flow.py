#!/usr/bin/env python3
"""Check one scenario of run.sh: python3 assert_flow.py <scenario> <playbook rc>."""
import json
import sys

scenario, rc = sys.argv[1], int(sys.argv[2])
calls = [json.loads(line) for line in open('/tmp/calls.jsonl')]
out = open('/tmp/out.txt').read()
mods = [c['module'] for c in calls]
NAA = 'naa.624a937000112233445566778899aabb'
problems = []


def need(condition, message):
    if not condition:
        problems.append(message)


def of(module):
    return [c['params'] for c in calls if c['module'] == module]


clone, files = of('vmware_vmdk_clone'), of('vsphere_file')
# Whatever happened before, the always section removes the RDM files, disconnects the volume and rescans.
need(mods[-4:] == ['vsphere_file', 'vsphere_file', 'purefa_host', 'vmware_host_scanhba'], 'cleanup calls missing at the end: %s' % mods)
need(len(files) == 2 and {f['path'] for f in files} == {'lin-server01_temp_0.vmdk', 'lin-server01_temp_0-rdmp.vmdk'},
     'RDM descriptor and mapping file must both be removed: %s' % [f['path'] for f in files])
need(all(f['state'] == 'absent' and f['datacenter'] == 'ha-datacenter' and f['datastore'] == 'ds1' for f in files),
     'vsphere_file must delete on the ESXi host (datacenter ha-datacenter) in the source datastore')
need(of('purefa_host')[-1]['state'] == 'absent', 'the volume must be disconnected from the host object last')

if scenario in ('A', 'B', 'C'):
    need(len(clone) == 1, 'expected exactly one clone call, got %d' % len(clone))
    c = clone[0] if clone else {}
    need(c.get('hostname') == '192.0.2.10', 'clone must log in to the ESXi host (ansible_host), not vCenter')
    need(c.get('username') == 'root' and c.get('password') == 's3cret-test', 'ESXi login must come from the hypervisors inventory host')
    need(c.get('source') == '[ds1] vm/vm.vmdk' and c.get('destination') == '[ds1] lin-server01_temp_0.vmdk', 'source/destination paths')
    need(c.get('disk_format') == 'rdmp' and c.get('device') == NAA, 'must clone as a physical RDM onto the new LUN')
    need(c.get('force') is True and int(c.get('timeout')) == 14400, 'force true and the clone_timeout default')
    need(len(of('vmware_host_scsidisk_info')) == 2, 'the device wait must poll until the LUN appears (2 polls expected)')
if scenario == 'A':
    need(rc == 0 and 'Cloned 40G from [ds1] vm/vm.vmdk' in out, 'happy path must succeed and report throughput')
if scenario == 'B':
    need(rc != 0 and 'failed in task' in out and 'stub clone failure' in out, 'a failed clone must fail the run with the task name and cause')
if scenario == 'C':
    need(rc == 0 and out.count('WARNING: could not remove') == 2, 'failed file deletes must warn once per file and not fail the run')
if scenario == 'D':
    need(rc != 0 and not clone, 'an unaccelerated device must stop the run before the clone')
    need('vStorageUnsupported' in out, 'the stop message must show the status')

print('   %s: %s' % (scenario, 'PASS' if not problems else 'FAIL'))
for p in problems:
    print('      - ' + p)
sys.exit(1 if problems else 0)
