# Build from the repository root:
#   docker build -f docker/Dockerfile -t disk-usage-monitor .
FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY disk_monitor.sh /usr/local/bin/disk_monitor.sh
RUN chmod +x /usr/local/bin/disk_monitor.sh

ENTRYPOINT ["/usr/local/bin/disk_monitor.sh"]
