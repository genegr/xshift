#!/bin/bash
# Run a kolla-ansible command from the deployer container against openstack00.
# Config/state live in the 'kolla-config' Docker volume; --network host avoids
# docker0 (172.17.0.0/16) shadowing the target's subnet when the two overlap.
# Usage: ./kolla.sh <command> [extra args]     e.g. ./kolla.sh deploy
cmd="$1"; shift
exec sudo docker run --rm --network host -v kolla-config:/config kolla-deployer:2026.1 \
  kolla-ansible "$cmd" -i /config/inventory \
  --configdir /config/etc-kolla \
  --passwords /config/etc-kolla/passwords.yml "$@"
