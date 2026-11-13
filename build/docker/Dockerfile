FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y build-essential clang flex bison g++ gawk gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev python3-setuptools python3-dev rsync swig unzip zlib1g-dev file wget curl time xz-utils zstd ca-certificates python3-pyelftools libelf-dev quilt less vim-tiny bc && rm -rf /var/lib/apt/lists/*
USER ubuntu
WORKDIR /src
