FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends qemu-system-mips ipxe-qemu openssh-client iproute2 busybox iperf3 tcpdump iputils-ping procps && rm -rf /var/lib/apt/lists/*
WORKDIR /work
