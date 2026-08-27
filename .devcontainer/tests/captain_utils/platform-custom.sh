#!/bin/bash
# handle_platform_upgrades: the pinned path must be byte-identical, and "custom" (install the platform chart from a local
# directory) must behave on clean/dirty/non-git checkouts, bad input, declines and helm failures — with stubbed gum/helm and
# real git/yq. Cases P0 + D1-D14 are the feature's own; A1-A18 came out of the adversarial review (spaces, CDPATH, ~user,
# xtrace, unbound variables, ...).
set -e -u -o pipefail
# shellcheck source=stubs.sh
source "$(dirname "$0")/stubs.sh"

# chart fixtures: a clean git checkout on a branch, a dirty one, a plain non-git dir, a dir without Chart.yaml, another chart name
mk_chart() { mkdir -p "$1/templates"; printf 'apiVersion: v2\nname: %s\nversion: %s\n' "$2" "$3" > "$1/Chart.yaml"; echo 'x: 1' > "$1/templates/a.yaml"; }
mk_chart "$T/clean" glueops-platform 0.78.0; git -C "$T/clean" init -q -b feat/my-thing; git -C "$T/clean" -c user.email=t@t -c user.name=t add -A; git -C "$T/clean" -c user.email=t@t -c user.name=t commit -q -m "feat: my thing"; CLEAN_SHA=$(git -C "$T/clean" rev-parse --short HEAD)
cp -r "$T/clean" "$T/dirty"; echo 'y: 2' >> "$T/dirty/templates/a.yaml"
mk_chart "$T/plain" glueops-platform 0.77.0
mkdir -p "$T/nochart"
mk_chart "$T/other" something-else 1.0.0
mkdir -p "$T/work/VERSIONS"; printf 'versions:\n- name: glueops_platform_helm_chart_version\n  version: "v0.77.0"\n' > "$T/work/VERSIONS/glueops.yaml"

run()    { local n=$1 e=$2 i=$3; shift 3; run_case     "$n" "$e" "$i" handle_platform_upgrades "$@"; }
runraw() { local n=$1 e=$2 i=$3; shift 3; run_case_raw "$n" "$e" "$i" handle_platform_upgrades "$@"; }

run "P0 pinned path unchanged" production "" v0.77.0
expect 'HELM diff --color upgrade glueops-platform glueops-platform/glueops-platform --version v0.77.0 -f platform.yaml -f platform.yaml -n glueops-core --allow-unreleased'
expect 'HELM upgrade --install glueops-platform glueops-platform/glueops-platform --version v0.77.0 -f platform.yaml -f platform.yaml -n glueops-core --create-namespace'; refute 'description'; expect "RC=0"; expect 'GUM CHOOSE \[v0.77.0 custom Back\]'

run "D1 clean git checkout, production: warning, info, diff, upgrade with description" production "$T/clean" custom
expect "UNRELEASED chart"; expect "chart glueops-platform 0.78.0 from $T/clean (feat/my-thing@$CLEAN_SHA)"; refute "note: Chart.yaml name"
expect "HELM diff --color upgrade glueops-platform $T/clean -f platform.yaml -f platform.yaml -n glueops-core --allow-unreleased"
expect "HELM upgrade --install glueops-platform $T/clean -f platform.yaml -f platform.yaml -n glueops-core --create-namespace --description custom: $T/clean (feat/my-thing@$CLEAN_SHA)"; expect "RC=0"
run "D2 dirty checkout flagged" dev "$T/dirty" custom
refute "UNRELEASED chart"; expect "(feat/my-thing@$CLEAN_SHA, dirty)"; expect "description custom: $T/dirty (feat/my-thing@$CLEAN_SHA, dirty)"; expect "RC=0"
run "D3 plain directory (not git): description is just the path" dev "$T/plain" custom
expect "chart glueops-platform 0.77.0 from $T/plain"; expect "description custom: $T/plain"; refute "@"; expect "RC=0"
run "D4 not a directory" dev "$T/nope" custom
expect "is not a directory"; refute "HELM"; expect "RC=0"
run "D5 no Chart.yaml" dev "$T/nochart" custom
expect "has no Chart.yaml"; refute "HELM"; expect "RC=0"
run "D6 other chart name: note, still confirmable" dev "$T/other" custom
expect "note: Chart.yaml name is 'something-else' but it will be installed as release 'glueops-platform'"; expect "HELM upgrade"; expect "RC=0"
run "D7 empty path = back" dev "" custom
refute "HELM"; refute "chart glueops-platform"; expect "RC=0"
run "D8 relative path resolved, trailing slash dropped, ~ expanded" dev "clean/" custom
cp -r "$T/clean" "$T/work/clean"; run "D8 relative path resolved, trailing slash dropped" dev "clean/" custom
expect "from $T/work/clean ("; expect "description custom: $T/work/clean"; expect "RC=0"
ln -s "$T/plain" "$HOME/.platform-custom-test-$$"
# shellcheck disable=SC2088   # the literal ~/ is the input under test
run "D8b ~ expanded (symlink resolved)" dev "~/.platform-custom-test-$$" custom
rm -f "$HOME/.platform-custom-test-$$"
expect "from $T/plain"; expect "RC=0"
confirms 1; run "D9 decline the diff prompt" dev "$T/clean" custom
expect "chart glueops-platform"; refute "HELM"; expect "RC=0"
confirms 0 1; run "D10 diff shown, decline upgrade" dev "$T/clean" custom
expect "HELM diff"; refute "HELM upgrade"; expect "RC=0"
confirms
HELM_DIFF_RC=1 run "D11 helm diff fails" dev "$T/clean" custom
expect "helm diff failed"; refute "HELM upgrade"; expect "RC=0"
HELM_UPGRADE_RC=1 run "D12 helm upgrade fails" dev "$T/clean" custom
expect "helm upgrade failed"; expect "RC=0"
touch "$T/work/overrides.yaml"; run "D13 overrides.yaml passed through" dev "$T/clean" custom
expect "Overrides.yaml detected"; expect "$T/clean -f platform.yaml -f overrides.yaml -n glueops-core --create-namespace --description"; expect "RC=0"
rm -f "$T/work/overrides.yaml"
GIT_DIR="$T/work/.git" run "D14 exported GIT_DIR ignored for the info line" dev "$T/clean" custom
expect "(feat/my-thing@$CLEAN_SHA)"; expect "RC=0"
grep -q '^+ ' "$T/out" && echo "  (xtrace lines present as in the pinned path)" || true

runraw "A1 EOF at the prompt with no newline (Ctrl-D): back, rc 0" dev "" custom
refute "HELM"; refute "chart glueops-platform"; expect "RC=0"; refute "unbound"
run "A2 a FILE instead of a directory" dev "$T/clean/Chart.yaml" custom
expect "is not a directory"; refute "HELM"; expect "RC=0"
mkdir -p "$T/locked"; cp "$T/plain/Chart.yaml" "$T/locked/"; chmod 000 "$T/locked"
run "A3 mode-000 directory (uid $(id -u))" dev "$T/locked" custom
expect "RC=0"; refute "HELM"; grep -E "is not a directory|has no Chart.yaml|cannot enter" "$T/out" >/dev/null && echo "  (refused)" || true
chmod 755 "$T/locked"
mk_chart "$T/space dir" glueops-platform 0.79.0
run "A4 path with a space (typed plainly, via pipe)" dev "$T/space dir" custom
expect "chart glueops-platform 0.79.0 from $T/space dir"; expect "HELM upgrade --install glueops-platform $T/space dir -f"; expect "description custom: $T/space dir"; expect "RC=0"
run "A4b path with a space, readline-escaped as Tab completion inserts it (read -r keeps the backslash)" dev "$T/space\\ dir" custom
expect "RC=0"; grep -q "is not a directory" "$T/out" && echo "  REPRO: escaped path rejected -> $(grep -o "'.*' is not a directory" "$T/out")"
ln -s "$T/work/clean" "$T/work/link"; run "A5 trailing slash on a symlinked dir" dev "$T/work/link/" custom
expect "from $T/work/clean ("; expect "RC=0"
mkdir -p "$T/badyaml"; printf 'name: [unterminated\nversion: 1\n' > "$T/badyaml/Chart.yaml"
run "A6 Chart.yaml that yq cannot parse" dev "$T/badyaml" custom
expect "RC=0"; refute "HELM upgrade"; grep -n "chart .* from\|note:\|Error\|error" "$T/out" | head -5 || true
mkdir -p "$T/noname"; printf 'apiVersion: v2\nversion: 1.2.3\n' > "$T/noname/Chart.yaml"
run "A7 Chart.yaml without a name" dev "$T/noname" custom
expect "RC=0"; grep -n "chart .* from\|note:" "$T/out" | head -3 || true
run "A8 the path '-' (cd - echoes OLDPWD into the captured path)" dev "-" custom
expect "RC=0"; grep -n "is not a directory\|chart .* from" "$T/out" | head -3 || true
cp -r "$T/clean" "$T/cdp"; run "A9 CDPATH exported by the operator, relative name that only CDPATH resolves" dev "cdp" custom
expect "RC=0"; grep -n "is not a directory\|chart .* from" "$T/out" | head -3 || true
CDPATH="$T" run "A9b same with CDPATH=\$T" dev "cdp" custom
expect "RC=0"; grep -n "is not a directory\|chart .* from" "$T/out" | head -3 || true
confirms 130; run "A10 gum confirm rc 130 (Esc/Ctrl-C) at the diff prompt" dev "$T/clean" custom
refute "HELM"; expect "RC=0"; refute "+ echo"
confirms 0 130; run "A11 gum confirm rc 130 at the upgrade prompt: xtrace must be off afterwards" dev "$T/clean" custom
expect "HELM diff"; refute "HELM upgrade"; expect "RC=0"; refute "+ echo"
confirms
HELM_DIFF_RC=1 run "A12 helm diff fails: xtrace off afterwards" dev "$T/clean" custom
expect "helm diff failed"; expect "RC=0"; refute "+ echo"; refute "+ gum style"
HELM_UPGRADE_RC=1 run "A13 helm upgrade fails: xtrace off afterwards" dev "$T/clean" custom
expect "helm upgrade failed"; expect "RC=0"; refute "+ echo"
mkdir -p "$T/mono/charts"; cp -r "$T/plain" "$T/mono/charts/platform"; git -C "$T/mono" init -q -b main; git -C "$T/mono" -c user.email=t@t -c user.name=t add -A; git -C "$T/mono" -c user.email=t@t -c user.name=t commit -q -m init; echo junk > "$T/mono/unrelated.txt"
run "A14 chart subdir inside a larger repo; unrelated untracked file outside it does NOT mark it dirty" dev "$T/mono/charts/platform" custom
expect "(main@"; refute ", dirty)"; expect "RC=0"   # dirty is scoped to the chart directory (git status -- .)
run "A15 ~user prefix (bash tilde semantics differ)" dev "~root/x" custom
expect "RC=0"; grep -o "'[^']*' is not a directory" "$T/out"
run "A16 production + dev: no unbound variables anywhere on the custom path" production "$T/clean" custom
refute "unbound"; expect "RC=0"
run "A17 relative '.' (the captain repo itself, no Chart.yaml)" dev "." custom
expect "has no Chart.yaml"; expect "RC=0"
run "A18 whitespace-only input is treated as empty (read strips IFS)" dev "   " custom
refute "HELM"; refute "not a directory"; expect "RC=0"

finish
