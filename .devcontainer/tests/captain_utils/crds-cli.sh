#!/bin/bash
# The crds command itself (libexec/captain_utils/crds), run as a subprocess through the same PATH shim: pure-validation
# paths that must refuse before any helm/kubectl call. No cluster, no network.
set -e -u -o pipefail
# shellcheck source=stubs.sh
source "$(dirname "$0")/stubs.sh"
CRDS=$CAPTAIN_UTILS_LIBEXEC/crds
mkdir -p "$T/work/VERSIONS"; printf 'versions:\n- name: platform_crds_version\n  version: "v0.0.1"\n' > "$T/work/VERSIONS/glueops.yaml"
run() { local n=$1 e=$2; shift 2; echo "##### $n #####"; ( cd "$T/work" && environment="$e" "$CRDS" "$@"; echo "RC=$?" ) > "$T/out" 2>&1 || echo "RC=$?" >> "$T/out"; cat "$T/out"; }

run "C1 prod target-version reads the pin" production target-version
expect '^v0.0.1$'; expect "RC=0"
run "C2 apply '' refuses (would make helm pull LATEST)" production apply ''
expect "must be a release tag vX.Y.Z"; expect "check VERSIONS/glueops.yaml"; refute "HELM"; expect "RC=1"
run "C3 apply garbage refuses" production apply latest
expect "must be a release tag vX.Y.Z"; refute "HELM"; expect "RC=1"
run "C4 unknown verb -> usage, rc 2" production bogus
expect "^usage:"; expect "RC=2"
run "C5 apply-dir '' refuses" production apply-dir ''
expect "is not a directory"; refute "HELM"; refute "KUBECTL"; expect "RC=1"
mkdir -p "$T/nochart/crds"; touch "$T/nochart/crds/a.yaml"
run "C6 apply-dir without Chart.yaml refuses" production apply-dir "$T/nochart"
expect "not a rendered platform-crds checkout"; refute "HELM"; refute "KUBECTL"; expect "RC=1"
mkdir -p "$T/empty/crds"; printf 'name: platform-crds\nversion: 1.0.0\n' > "$T/empty/Chart.yaml"
run "C7 apply-dir with empty crds/ refuses" production apply-dir "$T/empty"
expect "not a rendered platform-crds checkout"; refute "HELM"; refute "KUBECTL"; expect "RC=1"
mkdir -p "$T/other/crds"; printf 'name: glueops-platform\nversion: 1.0.0\n' > "$T/other/Chart.yaml"; printf -- '---\nkind: CustomResourceDefinition\n' > "$T/other/crds/a.yaml"
run "C8 apply-dir with another chart name refuses" production apply-dir "$T/other"
expect "is chart 'glueops-platform', not platform-crds"; refute "HELM"; refute "KUBECTL"; expect "RC=1"
mkdir -p "$T/nosep/crds"; printf 'name: platform-crds\nversion: 1.0.0\n' > "$T/nosep/Chart.yaml"; printf 'kind: CustomResourceDefinition\n' > "$T/nosep/crds/a.yaml"
run "C9 apply-dir with a crds/*.yaml not starting with --- refuses" production apply-dir "$T/nosep"
expect "must start with ---"; refute "HELM"; refute "KUBECTL"; expect "RC=1"

finish
