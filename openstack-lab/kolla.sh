#!/bin/bash
# Run a kolla-ansible command from the deployer container against openstack00.
# Config/state live in the 'kolla-config' Docker volume; --network host avoids the
# docker0 (172.17/16) overlap with openstack00's 172.17.20.0/24.
# Usage: ./kolla.sh <command> [extra args]     e.g. ./kolla.sh deploy
cmd="$1"; shift
exec sudo docker run --rm --network host -v kolla-config:/config kolla-deployer:2026.1 \
  kolla-ansible "$cmd" -i /config/inventory \
  --configdir /config/etc-kolla \
  --passwords /config/etc-kolla/passwords.yml "$@"
