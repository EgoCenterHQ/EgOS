# EgOS arm64 (Raspberry Pi 5) image builder: the tools only, no state (docker or podman).
# Used by build-img.sh; by hand: docker build -t egos-builder-arm64 builder-arm64-raspPi/
FROM docker.io/library/debian:trixie
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      mmdebstrap arch-test qemu-user qemu-user-binfmt e2fsprogs dosfstools mtools fdisk \
      curl ca-certificates gnupg util-linux \
 && rm -rf /var/lib/apt/lists/*
COPY build-in-container.sh /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/build-in-container.sh"]
