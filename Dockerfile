# Migration runner image: runs the vSphere -> OpenStack migration playbooks.
# Build:  docker build -t vsphere-os-migration .
# Run:    docker run --rm -it -v "$PWD":/work -w /work vsphere-os-migration \
#             ansible-playbook migrate_vm.yaml --ask-vault-pass
FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    ANSIBLE_HOST_KEY_CHECKING=False \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-client sshpass ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Python deps, pinned in requirements.txt so the image rebuilds the same way:
#   ansible-core
#   openstacksdk / python-openstackclient -> OpenStack stage (openstack.cloud + CLI)
#   pyvmomi                               -> community.vmware (vSphere stage)
#   py-pure-client                        -> everpure.flasharray (Pure stage; large)
COPY requirements.txt /tmp/requirements.txt
RUN pip install -r /tmp/requirements.txt

COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -r /tmp/requirements.yml

WORKDIR /work
CMD ["bash"]
