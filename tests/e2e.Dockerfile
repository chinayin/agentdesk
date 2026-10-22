ARG BASE_IMAGE=ubuntu:26.04
FROM ${BASE_IMAGE}
ARG TARGETARCH
ENV container=docker
# 仅安装测试基础设施；产品软件由真实 install.sh 安装。
RUN --mount=type=cache,id=agentdesk-e2e-apt-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && printf 'Acquire::Retries "3";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' > /etc/apt/apt.conf.d/80-e2e-network \
    && apt-get -o APT::Update::Error-Mode=any update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd systemd-sysv dbus ca-certificates xvfb xauth xdotool x11-utils scrot \
    && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
