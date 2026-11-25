#!/usr/bin/python
# Stub for one module of community.vmware / everpure.flasharray; run.sh substitutes the name.
# It records every call in /tmp/calls.jsonl and returns canned data. Nothing talks to a real system.
import json
import os
import time

from ansible.module_utils.basic import AnsibleModule

NAME = '__NAME__'
SERIAL = '00112233445566778899AABB'
NAA = 'naa.624a9370' + SERIAL.lower()
KEYS = ('hostname username password validate_certs esxi_hostname source destination disk_format device force '
        'timeout datacenter datastore path state refresh_storage rescan_hba rescan_vmfs create_folders name size '
        'fa_url api_token volume personality wwns iqn').split()


def main():
    module = AnsibleModule(argument_spec={k: dict(type='raw') for k in KEYS})
    p = module.params
    with open('/tmp/calls.jsonl', 'a') as f:
        f.write(json.dumps({'module': NAME, 'params': p}, default=str) + '\n')
    result = dict(changed=True)
    if NAME == 'purefa_volume':
        result['volume'] = {p['name']: {'serial': SERIAL, 'page83_naa': NAA}}
    elif NAME == 'vmware_host_scsidisk_info':
        counter = '/tmp/lun_counter'
        n = int(open(counter).read()) + 1 if os.path.exists(counter) else 1
        open(counter, 'w').write(str(n))
        luns = [{'canonical_name': 'naa.local0', 'vStorageSupport': 'vStorageUnsupported'}]
        if n >= 2:  # the device shows up on the second poll, to exercise until/retries
            luns.append({'canonical_name': NAA, 'vStorageSupport': os.environ.get('VSTORAGE') or 'vStorageSupported'})
        result = dict(changed=False, hosts_scsidisk_info={'esxi03.example': luns})
    elif NAME == 'vmware_vmdk_clone':
        time.sleep(1.5)
        if os.environ.get('FAIL_CLONE'):
            module.fail_json(msg='stub clone failure')
    elif NAME == 'vsphere_file':
        if os.environ.get('FAIL_DELETE'):
            module.fail_json(msg='stub delete failure')
    module.exit_json(**result)


if __name__ == '__main__':
    main()
