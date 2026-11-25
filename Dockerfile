# Migration runner image: runs the vSphere -> OpenStack migration playbooks.
# Build:  docker build -t vsphere-os-migration .
# Run:    docker run --rm -it -v "$PWD":/work -w /work vsphere-os-migration \
#             ansible-playbook migrate_vm.yaml --ask-vault-pass
FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1

# git: ansible-galaxy clones community.vmware (vmware_vmdk_clone) from its repository.
# No SSH client is needed: ESXi is driven through its vSphere API.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Python deps, pinned in requirements.txt so the image rebuilds the same way:
#   ansible-core                          -> 2.21 or later, required by community.vmware
#   openstacksdk / python-openstackclient -> OpenStack stage (openstack.cloud + CLI)
#   pyvmomi                               -> community.vmware (vSphere stage)
#   py-pure-client                        -> everpure.flasharray (Pure stage; large)
COPY requirements.txt /tmp/requirements.txt
RUN pip install -r /tmp/requirements.txt

COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -r /tmp/requirements.yml

WORKDIR /work
CMD ["bash"]
