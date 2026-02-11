FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y \
    bash curl wget git openssh-client jq python3 python3-pip \
    nano vim htop ripgrep fd-find make g++ cmake \
    && rm -rf /var/lib/apt/lists/*
RUN npm install -g openclaw@2026.2.9
RUN useradd -m -s /bin/bash agent
USER agent
WORKDIR /home/agent
RUN echo 'PS1="agent@claw:\\w\\$ "' >> /home/agent/.bashrc
ENV NODE_OPTIONS=--max-old-space-size=768
CMD ["sleep", "infinity"]
