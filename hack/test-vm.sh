#!/bin/bash
# Offline checks for the VM metrics pieces under vm/: shell syntax, shellcheck (when installed), the structural
# contract between the files, and — when a collector binary is available — `otelcol-contrib validate` of the config.
#
# The collector binary is not required: locally the validate step is skipped unless otelcol-contrib is on the PATH
# or OTELCOL_BIN points at one. CI downloads the pinned release so validate always runs there.
# The real end-to-end proof (units start, receivers produce data, the gate holds) is the smoke test inside
# vm/observability.sh, which runs in the Packer build VM.
set -e -u -o pipefail
cd "$(dirname "$0")/.."
fail=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; fail=1; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "== bash -n"
bash -n vm/observability.sh hack/test-vm.sh
if command -v shellcheck >/dev/null; then
    echo "== shellcheck $(shellcheck --version | awk '/^version:/{print $2}')"
    shellcheck -S warning vm/observability.sh hack/test-vm.sh
else
    echo "== shellcheck: not installed, skipped"
fi

echo "== contract"
# The version the installer downloads is the one CI validates against, and renovate can find it.
check "installer pins one renovate-annotated collector version" \
    '[ "$(grep -c "^VERSION_OTELCOL_CONTRIB=" vm/observability.sh)" = 1 ] && grep -B1 "^VERSION_OTELCOL_CONTRIB=" vm/observability.sh | grep -q "renovate: datasource=github-releases depName=open-telemetry/opentelemetry-collector-releases"'
# Inert-without-the-file is the back-compat contract with VMs the bot never configured.
check "drop-in gates the unit on /etc/glueops/otel.env" \
    'grep -q "^ConditionPathExists=/etc/glueops/otel.env$" vm/otelcol/glueops.conf && grep -q "^EnvironmentFile=/etc/glueops/otel.env$" vm/otelcol/glueops.conf'
check "drop-in orders after docker and cloud-init config stage" \
    'grep -q "^After=.*docker.service" vm/otelcol/glueops.conf && grep -q "^After=.*cloud-config.service" vm/otelcol/glueops.conf'
# Nothing per-VM may be baked into the image: the endpoint has to come from otel.env.
check "config takes the endpoint from the environment, not a literal" \
    'grep -q "endpoint: \${env:OTEL_EXPORTER_OTLP_ENDPOINT}" vm/otelcol/config.yaml && ! grep -q "glueopshosted" vm/otelcol/config.yaml'
check "config has the memory_limiter backstop in the pipeline" \
    'grep -q "processors: \[memory_limiter," vm/otelcol/config.yaml'
check "node exporter binds loopback only" \
    'grep -q -- "--web.listen-address=127.0.0.1:9100" vm/node-exporter/prometheus-node-exporter.default'
check "installer stops the postinst instance and re-checks the gate" \
    'grep -q "systemctl stop otelcol-contrib" vm/observability.sh && grep -q "ConditionPathExists gate is broken" vm/observability.sh'
check "packer uploads vm/ and runs the installer after developer-setup.sh" \
    'grep -q "source *= *\"vm\"" qemu.pkr.hcl && grep -A3 "\"developer-setup.sh\"" qemu.pkr.hcl | grep -q "\"vm/observability.sh\""'

echo "== otelcol-contrib validate"
bin=${OTELCOL_BIN:-$(command -v otelcol-contrib || true)}
if [ -n "$bin" ]; then
    want=$(sed -n 's/^VERSION_OTELCOL_CONTRIB=//p' vm/observability.sh)
    have=$("$bin" --version | awk '{print $NF}')
    [ "$have" = "$want" ] && ok "binary is the pinned version $want" || echo "  note  validating with $have, image pins $want"
    if OTEL_EXPORTER_OTLP_ENDPOINT=https://example.invalid "$bin" validate --config vm/otelcol/config.yaml; then
        ok "config validates"
    else
        bad "config does not validate"
    fi
    # A config that validates without the endpoint would silently ship an image whose collector runs with none.
    if "$bin" validate --config vm/otelcol/config.yaml >/dev/null 2>&1; then
        bad "config validates without OTEL_EXPORTER_OTLP_ENDPOINT set"
    else
        ok "config refuses to start without OTEL_EXPORTER_OTLP_ENDPOINT"
    fi
else
    echo "  skipped: no otelcol-contrib on PATH and OTELCOL_BIN unset"
fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "FAILED"; exit 1; }
