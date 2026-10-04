# Migration runner image: runs the vSphere -> OpenStack migration playbooks.
# Build:  docker build -t vsphere-os-migration .
# Run:    docker run --rm -it -v "$PWD":/work -w /work vsphere-os-migration \
#             ansible-playbook -i inventory.yaml migrate_vm.yaml
FROM python:3.12-slim

ENV DEBIAN_FRONTEND=noninteractive \
    ANSIBLE_HOST_KEY_CHECKING=False \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-client sshpass ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Python deps for the three stages:
#   openstacksdk / *client  -> OpenStack stage
#   pyvmomi                 -> community.vmware (vSphere stage)
#   py-pure-client          -> purestorage.flasharray (Pure stage)
RUN pip install \
      ansible-core \
      openstacksdk \
      python-openstackclient \
      python-cinderclient \
      pyvmomi \
      py-pure-client

COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -r /tmp/requirements.yml

WORKDIR /work
CMD ["bash"]
