# QEMU, OVMF and the few tools the VM harness drives them with. The host has no root, so all of it lives here.
FROM debian:stable-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils ovmf \
      python3 python3-pexpect sshpass openssh-client \
      e2fsprogs libarchive-tools gnupg dirmngr ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
# ssh refuses to run for a uid without a passwd entry, and the container runs as the host user.
ARG UID=1000
ARG GID=1000
RUN groupadd -o -g "$GID" gi && useradd -o -m -u "$UID" -g "$GID" gi
