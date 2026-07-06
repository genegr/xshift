# Derived cinder-volume image that adds py-pure-client (required by the Pure driver,
# not present in the stock kolla image). Build ON openstack00 and push to the local
# registry:
#   docker build -t localhost:4000/cinder-volume-pure:2026.1 -f cinder-pure.Dockerfile .
#   docker push localhost:4000/cinder-volume-pure:2026.1
FROM quay.io/openstack.kolla/cinder-volume:2026.1-ubuntu-noble
USER root
RUN /var/lib/kolla/venv/bin/pip install --no-cache-dir py-pure-client
USER cinder
