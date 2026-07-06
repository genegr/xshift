#!/bin/bash
# =============================================================================
# Reproducible setup of the single-node OpenStack 2026.1 AIO used to develop the
# migration playbooks. Deployer runs containerized on the dev/jump box; OpenStack
# is deployed to openstack00 over SSH. Run the numbered blocks from the dev box.
#
# This is a runbook: read it, set the vars, run block by block. It is NOT fully
# idempotent end to end.
# =============================================================================
set -euo pipefail

# --- Parameters --------------------------------------------------------------
TARGET_IP="172.17.20.101"          # openstack00 management IP (network_interface = ens34)
TARGET_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_rsa"        # key that authenticates as ubuntu@openstack00
PURE_SAN_IP="10.225.112.90"
PURE_API_TOKEN="REPLACE_ME"        # do NOT commit; goes into passwords.yml only
HERE="$(cd "$(dirname "$0")" && pwd)"

# --- 1. Build the kolla-ansible deployer image (dev box) ---------------------
sudo docker build -t kolla-deployer:2026.1 -f "$HERE/Dockerfile.deployer" "$HERE"

# --- 2. Create the config volume and populate it -----------------------------
sudo docker volume create kolla-config
# 2a. sample config + inventory (inventory: retarget all groups to openstack00)
sudo docker run --rm -v kolla-config:/config kolla-deployer:2026.1 bash -c '
  mkdir -p /config/etc-kolla/config /config/ssh
  cp /usr/local/share/kolla-ansible/etc_examples/kolla/globals.yml   /config/etc-kolla/
  cp /usr/local/share/kolla-ansible/etc_examples/kolla/passwords.yml /config/etc-kolla/
  sed "s/localhost       ansible_connection=local/openstack00 ansible_host='"$TARGET_IP"'/" \
    /usr/local/share/kolla-ansible/ansible/inventory/all-in-one > /config/inventory
  cat >> /config/inventory <<EOF

[all:vars]
ansible_user='"$TARGET_USER"'
ansible_become=true
ansible_ssh_private_key_file=/config/ssh/id_rsa
ansible_ssh_common_args=-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
EOF'
# 2b. our overrides + cinder default-type override
sudo docker run --rm -i -v kolla-config:/config kolla-deployer:2026.1 \
  bash -c 'cat >> /config/etc-kolla/globals.yml' < "$HERE/globals.overrides.yml"
sudo docker run --rm -i -v kolla-config:/config kolla-deployer:2026.1 \
  bash -c 'cat > /config/etc-kolla/config/cinder.conf' < "$HERE/config/cinder.conf"
# 2c. ssh key into the volume
sudo docker run --rm -i -v kolla-config:/config kolla-deployer:2026.1 \
  bash -c 'cat > /config/ssh/id_rsa; chmod 600 /config/ssh/id_rsa' < "$SSH_KEY"
# 2d. passwords + the Pure API token (secret, not committed)
sudo docker run --rm -v kolla-config:/config kolla-deployer:2026.1 \
  bash -c "kolla-genpwd -p /config/etc-kolla/passwords.yml; \
           echo 'pure_api_token: $PURE_API_TOKEN' >> /config/etc-kolla/passwords.yml"

# --- 3. Prepare openstack00 (target) -----------------------------------------
ssh -i "$SSH_KEY" "$TARGET_USER@$TARGET_IP" 'sudo bash -s' <<'REMOTE'
set -e
# 3a. Free ports/services kolla needs (host services that conflict)
systemctl disable --now nginx 2>/dev/null || true          # frees :80 for Horizon
systemctl stop multipathd.service multipathd.socket multipath-tools.service 2>/dev/null || true
systemctl disable multipathd.service multipathd.socket 2>/dev/null || true
pkill -x multipathd 2>/dev/null || true
# 3b. Loopback-backed cinder-volumes LVM VG (+ persistence unit installed separately)
if ! vgs cinder-volumes >/dev/null 2>&1; then
  truncate -s 60G /var/lib/cinder-volumes.img
  losetup /dev/loop100 /var/lib/cinder-volumes.img
  pvcreate -f /dev/loop100
  vgcreate cinder-volumes /dev/loop100
fi
REMOTE
# 3c. install the loopback persistence unit
scp -i "$SSH_KEY" "$HERE/cinder-loop.service" "$TARGET_USER@$TARGET_IP:/tmp/"
ssh -i "$SSH_KEY" "$TARGET_USER@$TARGET_IP" \
  'sudo mv /tmp/cinder-loop.service /etc/systemd/system/ && sudo systemctl enable cinder-loop.service'

# --- 4. bootstrap + prechecks (installs docker on target) --------------------
"$HERE/kolla.sh" bootstrap-servers
"$HERE/kolla.sh" prechecks

# --- 5. Local registry + Pure-enabled cinder image (on openstack00) ----------
scp -i "$SSH_KEY" "$HERE/cinder-pure.Dockerfile" "$TARGET_USER@$TARGET_IP:/tmp/"
ssh -i "$SSH_KEY" "$TARGET_USER@$TARGET_IP" 'sudo bash -s' <<'REMOTE'
set -e
docker inspect registry >/dev/null 2>&1 || \
  docker run -d --name registry --restart=always --network host \
    -e REGISTRY_HTTP_ADDR=0.0.0.0:4000 registry:2
mkdir -p /tmp/cinder-pure && mv /tmp/cinder-pure.Dockerfile /tmp/cinder-pure/Dockerfile
docker build --network=host -t localhost:4000/cinder-volume-pure:2026.1 /tmp/cinder-pure
docker push localhost:4000/cinder-volume-pure:2026.1
REMOTE

# --- 6. Deploy + post-deploy -------------------------------------------------
"$HERE/kolla.sh" deploy
"$HERE/kolla.sh" post-deploy

# --- 7. Verify ---------------------------------------------------------------
"$HERE/osc.sh" service list
"$HERE/osc.sh" volume service list
echo "Done. Horizon: http://$TARGET_IP/  (admin password: grep OS_PASSWORD in the volume's admin-openrc.sh)"
