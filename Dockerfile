FROM ubuntu:24.04
ARG SRB_VER=3.8.7
ARG SRB_SHA256=1fe6e9098a27446f62bb7388dac549913852a56cb8fab76dd840b77f7498f612
ENV NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=compute,utility
# wget stays in the image: SRBMiner 3.8.6 exits (code 73) at startup without it.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl tini wget \
 && f=SRBMiner-Multi-$(echo $SRB_VER | tr . -)-Linux.tar.gz \
 && curl -fsSLo /tmp/$f https://github.com/doktor83/SRBMiner-Multi/releases/download/$SRB_VER/$f \
 && echo "$SRB_SHA256  /tmp/$f" | sha256sum -c - \
 && mkdir -p /opt/srbminer && tar -xzf /tmp/$f -C /opt/srbminer --strip-components=1 \
 && rm /tmp/$f && apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/srbminer
# SRBMiner exits silently as PID 1, and Vast default jobs have no --init option.
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/srbminer/SRBMiner-MULTI"]
