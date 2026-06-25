FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y \
    wireguard-tools \
    curl \
    jq \
    git \
    bash \
    openssh-client \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/pia-foss/manual-connections /opt/pia-manual-connections

# Container sleeps by default, woken by Unraid User Script
CMD ["sleep", "infinity"]
