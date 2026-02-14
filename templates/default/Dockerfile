FROM node:22-bookworm-slim

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  bash \
  build-essential \
  ca-certificates \
  cmake \
  curl \
  fd-find \
  git \
  htop \
  iproute2 \
  jq \
  nano \
  openssh-client \
  python3 \
  python3-pip \
  ripgrep \
  vim \
  wget \
  && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash agent && \
  mkdir -p /home/agent && chown -R agent:agent /home/agent

RUN ln -s /usr/bin/fdfind /usr/local/bin/fd

RUN cat <<'SCRIPT' > /usr/local/bin/openclaw-install && chmod +x /usr/local/bin/openclaw-install
#!/bin/sh
set -eu
npm install -g openclaw
openclaw --version
SCRIPT

RUN cat <<'BASHRC' > /home/agent/.bashrc
export PS1='[clawbox \u@\h \W]$ '
alias ll='ls -la'
alias gs='git status'
alias py='python3'
BASHRC

RUN chown agent:agent /home/agent/.bashrc

ENV NODE_OPTIONS=--max-old-space-size=768

USER agent
WORKDIR /home/agent

CMD ["sleep", "infinity"]
