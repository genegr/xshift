#!/bin/bash
# OpenStack CLI against the AIO cloud (admin creds from the deployer volume).
# Usage: ./osc.sh <args>      e.g. ./osc.sh server list ; ./osc.sh volume service list
exec sudo docker run --rm --network host -v kolla-config:/config kolla-deployer:2026.1 \
  bash -c "source /config/etc-kolla/admin-openrc.sh; exec openstack \"\$@\"" _ "$@"
