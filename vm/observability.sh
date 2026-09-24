#!/bin/bash
# VM metrics for the CDE image: prometheus-node-exporter + the OpenTelemetry Collector that ships it.
#
# Runs as a Packer shell provisioner (see qemu.pkr.hcl) after developer-setup.sh, which it depends on for Docker
# and the `docker` group. Files under vm/ are uploaded to $VM_FILES_DIR (default /tmp/vm) by the file provisioner.
#
# What lands on the VM:
#   prometheus-node-exporter   Debian package, bound to 127.0.0.1:9100         (vm/node-exporter/*.default)
#   otelcol-contrib            upstream .deb, pinned + checksum-verified below  (vm/otelcol/config.yaml)
#   systemd drop-in            makes the collector INERT until /etc/glueops/otel.env exists (vm/otelcol/glueops.conf)
#
# The Slack bot writes /etc/glueops/otel.env through cloud-init; nothing about the endpoint or the VM's identity is
# baked into the image. README, "VM metrics", documents that file's contract.
set -e -u -o pipefail

VM_FILES_DIR=${VM_FILES_DIR:-/tmp/vm}
# renovate: datasource=github-releases depName=open-telemetry/opentelemetry-collector-releases
VERSION_OTELCOL_CONTRIB=0.159.0

echo "--> node exporter (Debian package)"
# --no-install-recommends: the package recommends prometheus-node-exporter-collectors, a set of apt/smartmon cron
# jobs that these VMs have no use for.
sudo apt-get install -y --no-install-recommends prometheus-node-exporter
sudo install -m 0644 "$VM_FILES_DIR/node-exporter/prometheus-node-exporter.default" /etc/default/prometheus-node-exporter
sudo systemctl enable prometheus-node-exporter
sudo systemctl restart prometheus-node-exporter

echo "--> otelcol-contrib ${VERSION_OTELCOL_CONTRIB}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${VERSION_OTELCOL_CONTRIB}"
deb="otelcol-contrib_${VERSION_OTELCOL_CONTRIB}_linux_amd64.deb"
curl -fsSL -o "$tmp/$deb" "$base/$deb"
curl -fsSL -o "$tmp/$deb.sha256" "$base/$deb.sha256"
# The upstream .sha256 asset is the bare digest; sha256sum -c wants "digest  filename".
echo "$(cat "$tmp/$deb.sha256")  $deb" | (cd "$tmp" && sha256sum -c -)
# postinst enables the unit and starts it with the stock config. The stock config is replaced right below and the
# unit re-evaluated, so that first start is a few seconds of a default pipeline that exports nothing anywhere.
sudo dpkg -i "$tmp/$deb"

sudo install -m 0644 "$VM_FILES_DIR/otelcol/config.yaml" /etc/otelcol-contrib/config.yaml
sudo install -d -m 0755 /etc/systemd/system/otelcol-contrib.service.d
sudo install -m 0644 "$VM_FILES_DIR/otelcol/glueops.conf" /etc/systemd/system/otelcol-contrib.service.d/glueops.conf
# docker_stats reads /var/run/docker.sock. Membership in `docker` is root-equivalent on the host — acceptable on a
# single-tenant dev VM and the one privilege this setup grants; it is the same membership developer-setup.sh gives
# the vscode user.
sudo usermod -aG docker otelcol-contrib
sudo systemctl daemon-reload
sudo systemctl enable otelcol-contrib
# Stock-config instance from postinst: stop it. The drop-in's ConditionPathExists keeps it down from here on.
sudo systemctl stop otelcol-contrib

echo "--> smoke test"
# The build VM is the only place before release with a real systemd, Docker and node exporter, so prove the
# pieces fit here rather than on a developer's first boot. The endpoint override points at a closed local port:
# nothing leaves the build VM, and the collector's own startup does not depend on the endpoint answering.
sudo env OTEL_EXPORTER_OTLP_ENDPOINT=https://example.invalid /usr/bin/otelcol-contrib validate --config /etc/otelcol-contrib/config.yaml
sudo install -d -m 0755 /etc/glueops
printf 'OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:1\nOTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=packer-build\n' \
    | sudo tee /etc/glueops/otel.env >/dev/null
sudo chmod 0600 /etc/glueops/otel.env
sudo systemctl start otelcol-contrib
sleep 8
systemctl is-active prometheus-node-exporter otelcol-contrib
curl -fsS 127.0.0.1:9100/metrics | grep -q '^node_cpu_seconds_total' && echo "node exporter: serving node_* metrics"
# Both receivers have to have produced something: a docker_stats that failed to start would have killed the
# collector (is-active above), but a receiver that starts and silently yields nothing would not.
self=$(curl -fsS 127.0.0.1:8888/metrics)
grep -q 'otelcol_receiver_accepted_metric_points.*receiver="prometheus"' <<<"$self" && echo "collector: scraped node exporter"
grep -q 'otelcol_receiver_accepted_metric_points.*receiver="docker_stats"' <<<"$self" && echo "collector: read docker stats"
sudo systemctl stop otelcol-contrib
sudo rm -f /etc/glueops/otel.env
# Without the file the unit must stay down — that is the contract older VMs and hand-made VMs rely on.
if sudo systemctl start otelcol-contrib 2>/dev/null && systemctl is-active --quiet otelcol-contrib; then
    echo "otelcol-contrib started without /etc/glueops/otel.env; the ConditionPathExists gate is broken" >&2
    exit 1
fi
echo "collector: inert without /etc/glueops/otel.env"
echo "✅ VM metrics installed: node exporter ($(prometheus-node-exporter --version 2>&1 | head -1)), otelcol-contrib ${VERSION_OTELCOL_CONTRIB}"
