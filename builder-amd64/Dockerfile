# EgOS amd64 ISO builder: the tools only, no state (works with docker and podman).
# Used by build-iso.sh; by hand: docker build -t egos-builder builder-amd64/
FROM docker.io/library/debian:trixie
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      live-build curl ca-certificates gnupg \
 && rm -rf /var/lib/apt/lists/*
COPY build-in-container.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/build-in-container.sh"]
