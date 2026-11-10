#!/bin/bash
# app-chart-preflight against stubbed kubectl and argocd: discovery (sets, standalone, drift, wrong-kind targets),
# per-app verdicts and the 0.18.0 classification, the report, --appset/--save/--no-diff, a lost connection retried,
# and the exit codes. The stub "local Argo CD server" is python3's http.server serving /healthz. No cluster, no network.
set -e -u -o pipefail
REPO=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
TOOL=$REPO/.devcontainer/tools/app-chart-preflight.sh
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fix/render" "$T/fix/www" "$T/work"
touch "$T/fix/www/healthz"
export FIX=$T/fix

# ---- stubs ----
cat > "$T/bin/kubectl" <<'K'
#!/bin/bash
# current context "test-ctx"; config view prints a kubeconfig for it (any other context fails); get lists the fixtures
case "$*" in
  "config current-context") echo test-ctx ;;
  config\ view*) case "$*" in *"--context test-ctx"*) printf 'apiVersion: v1\nkind: Config\ncurrent-context: test-ctx\ncontexts: [{name: test-ctx, context: {cluster: c, user: u}}]\nclusters: [{name: c, cluster: {server: "https://x"}}]\nusers: [{name: u, user: {token: t}}]\n' ;;
                 *) echo 'error: context "nope" does not exist' >&2; exit 1 ;; esac ;;
  config\ set-context*) ;;
  get\ applicationsets*) cat "$FIX/appsets.json" ;;
  get\ applications*) cat "$FIX/apps.json" ;;
  *) echo "kubectl stub: unexpected $*" >&2; exit 1 ;;
esac
K
cat > "$T/bin/argocd" <<'A'
#!/bin/bash
# admin dashboard -> python http.server with /healthz; app manifests APP [--revision(s) R] -> $FIX/render/APP.{cur,new}.yaml,
# or that file's .err (exit 20); APP.flaky fails once with a lost connection; version -> v9.9.9
args=("$@"); [ "${args[0]}" = --config ] && args=("${args[@]:2}")
case "${args[0]} ${args[1]}" in
  "admin dashboard") exec python3 -m http.server "${args[3]}" --bind 127.0.0.1 --directory "$FIX/www" >/dev/null 2>&1 ;;
  "version --client") echo "argocd: v9.9.9+stub"; exit 0 ;;
  "app manifests")
    app=${args[2]}; side=cur
    for a in "${args[@]}"; do case "$a" in --revision|--revisions) side=new ;; esac; done
    echo "${args[*]}" >> "$FIX/calls.log"
    if [ -f "$FIX/render/$app.flaky" ]; then rm "$FIX/render/$app.flaky"; echo '{"level":"fatal","msg":"rpc error: code = Unavailable desc = connection reset by peer"}' >&2; exit 20; fi
    f="$FIX/render/$app.$side"
    if [ -f "$f.err" ]; then cat "$f.err" >&2; exit 20; fi
    cat "$f.yaml"; exit 0 ;;
esac
echo "argocd stub: unexpected $*" >&2; exit 1
A
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

# ---- fixtures ----
GIT='https://github.com/GlueOps/project-template-helm-chart-app.git'
HELM='https://helm.gpkg.io/project-template'
VALS='{"repoURL": "https://github.com/tenant/deployment-configurations", "targetRevision": "main", "ref": "values"}'
appset() { jq -n --arg n "$1" --argjson src "$2" --argjson v "$VALS" '{metadata: {name: $n}, spec: {template: {spec: {sources: [$src, $v]}}}}'; }
gitsrc() { jq -n --arg r "$1" --arg repo "$GIT" '{repoURL: $repo, path: ".", targetRevision: $r, helm: {valueFiles: ["$values/apps/x/values.yaml"]}}'; }
helmsrc() { jq -n --arg r "$1" --arg repo "$HELM" '{repoURL: $repo, chart: "app", targetRevision: $r}'; }
app() {  # name set src [sync]
    jq -n --arg n "$1" --arg s "$2" --argjson src "$3" --arg sync "${4:-Synced}" --argjson v "$VALS" \
        '{metadata: ({name: $n} + (if $s == "" then {} else {labels: {"argocd.argoproj.io/application-set-name": $s}} end)),
          spec: {destination: {namespace: "tenant"}, sources: [$src, $v]}, status: {sync: {status: $sync}}}'
}
deploy() {  # name args-json
    jq -n --arg n "$1" --argjson a "$2" '{apiVersion: "apps/v1", kind: "Deployment", metadata: {name: $n, labels: {"helm.sh/chart": "app-x"}},
        spec: {template: {metadata: {labels: {"helm.sh/chart": "app-x", app: $n}}, spec: {containers: [{name: "c", image: "i", args: $a}]}}}}' | yq -P
}
render() { deploy "$1" "$2" > "$FIX/render/$1.cur.yaml"; deploy "$1" "$3" > "$FIX/render/$1.new.yaml"; }
jq -n --argjson a "$(appset prod-set "$(gitsrc v0.17.1)")" --argjson b "$(appset helm-set "$(helmsrc 0.17.1)")" '{items: [$a, $b]}' > "$FIX/appsets.json"
jq -n --argjson a "$(app clean prod-set "$(gitsrc v0.17.1)")" --argjson b "$(app quoted prod-set "$(gitsrc v0.17.1)" OutOfSync)" \
      --argjson c "$(app mapitem prod-set "$(gitsrc v0.17.1)")" --argjson d "$(app drifted prod-set "$(gitsrc v0.16.1)")" \
      --argjson e "$(app noop prod-set "$(gitsrc v0.17.1)")" --argjson f "$(app h1 helm-set "$(helmsrc 0.17.1)")" \
      --argjson g "$(app hand-made "" "$(gitsrc v0.17.1)")" --argjson h "$(app platform "" "$(helmsrc 0.13.0)")" \
      --argjson i "$(app traefik "" '{"repoURL": "https://traefik.github.io/charts", "chart": "traefik"}')" \
      '{items: [$a, $b, $c, $d, $e, $f, $g, $h, $i]}' > "$FIX/apps.json"
render clean '["run"]' '["run"]'
render quoted '["echo a: b", "x"]' '["\"echo a: b\"", "x"]'
deploy mapitem '["map[a:b]"]' > "$FIX/render/mapitem.cur.yaml"
printf '%s\n' '{"level":"fatal","msg":"rpc error: failed to execute helm template: Error: execution error at (app/templates/deployment.yaml:1:2): deployment.args: every item must be a string (got map) - quote the item\nUse --debug flag to render out invalid YAML"}' > "$FIX/render/mapitem.new.err"
render noop '[null]' '[""]'
render h1 '["a"]' '["a"]'
render hand-made '["padded"]' '["  padded  "]'
render platform '["p"]' '["p"]'

# ---- harness ----
FAILS=0; CASES=0
run() { local name=$1; shift; echo "##### $name #####"; : > "$FIX/calls.log"
        ( cd "$T/work" && NO_COLOR=1 bash "$TOOL" "$@" ) > "$T/out" 2>&1 && rc=0 || rc=$?; echo "RC=$rc" >> "$T/out"; }
expect() { CASES=$((CASES+1)); if grep -qF -- "$1" "$T/out"; then echo "  ok: $1"; else echo "  FAIL: missing '$1'"; FAILS=$((FAILS+1)); sed 's/^/    | /' "$T/out"; fi; }
expect_re() { CASES=$((CASES+1)); if grep -qE -- "$1" "$T/out"; then echo "  ok: /$1/"; else echo "  FAIL: no match /$1/"; FAILS=$((FAILS+1)); sed 's/^/    | /' "$T/out"; fi; }
refute() { CASES=$((CASES+1)); if grep -qF -- "$1" "$T/out"; then echo "  FAIL: unexpected '$1'"; FAILS=$((FAILS+1)); else echo "  ok: no '$1'"; fi; }

run "P1 one target for every set: verdicts, classification, diff, exit 1" --target v0.18.0
expect_re '^prod-set +git +v0.17.1 +v0.18.0 +error +5 +2 +1 +1 +1 +0$'
expect_re '^helm-set +helm +0.17.1 +v0.18.0 +unknown +1 +0 +0 +0 +1 +0$'
expect_re '^standalone +- +- +v0.18.0 +diff +2 +0 +1 +0 +0 +1$'
expect_re 'quoted +OutOfSync +Deployment/quoted +c +args\[0\] +break +"echo a: b" +"\\"echo a: b\\"" +the item is wrapped'
expect_re 'hand-made +Synced +Deployment/hand-made +c +args\[0\] +roll +"padded" +"  padded  "'
expect "mapitem  tenant     Synced  deployment.args: every item must be a string (got map) - quote the item"
refute "Use --debug"
expect 'revision drift from ApplicationSet: app pins "v0.16.1", template pins "v0.17.1"'
expect 'target "v0.18.0" is not a chart version; a helm-sourced chart needs X.Y.Z (e.g. 0.18.0)'
expect "quoted (namespace tenant) values: apps/x/values.yaml"
expect "Pod template diffs"; expect "--- Deployment/quoted @ v0.17.1"; expect "+++ Deployment/quoted @ v0.18.0"
expect "-        - 'echo a: b'"; expect "+        - '\"echo a: b\"'"; refute "helm.sh/chart"
expect "Do NOT bump: prod-set (1 diff, 1 error), standalone (1 diff)"; expect "No verdict, run again: helm-set (1 unknown)"
refute "traefik"; expect "RC=1"
CASES=$((CASES+1)); if grep -qE 'app manifests quoted --revisions v0.18.0 --source-positions 1 --server 127.0.0.1:[0-9]+ --plaintext' "$FIX/calls.log"; then echo "  ok: target render uses --revisions/--source-positions on the local server"; else echo "  FAIL: target render args"; FAILS=$((FAILS+1)); fi

run "P2 per-set targets, one set clean: exit 0" --appset helm-set=0.18.0
expect_re '^helm-set +helm +0.17.1 +0.18.0 +ok +1 +1'; refute "prod-set"; refute "standalone"; expect "Safe to bump: helm-set"; expect "RC=0"

run "P3 standalone by name, helm app skipped with the expected form" --appset standalone=v0.18.0 --no-diff
expect_re '^standalone +- +- +v0.18.0 +diff'; expect '1 skipped: target "v0.18.0" is not a chart version'; refute "Pod template diffs"; expect "RC=1"

run "P4 a set that does not exist: exit 2" --appset nope=1.0.0
expect "no ApplicationSet that uses the app chart is named nope"; expect "nothing to check"; expect "RC=2"

touch "$FIX/render/h1.flaky"
run "P5 lost connection retried, --save" --appset helm-set=0.18.0 --save "$T/r.json"
expect_re '^helm-set .* ok '; expect "RC=0"; expect "Results saved to $T/r.json"
CASES=$((CASES+1)); if [ "$(grep -c 'app manifests h1' "$FIX/calls.log")" = 3 ]; then echo "  ok: h1 rendered 3 times (one retry)"; else echo "  FAIL: h1 calls"; FAILS=$((FAILS+1)); fi
CASES=$((CASES+1)); if jq -e '.apps[0].app == "h1" and .apps[0].status == "ok" and .appsets[0].status == "ok"' "$T/r.json" >/dev/null; then echo "  ok: saved JSON"; else echo "  FAIL: saved JSON"; FAILS=$((FAILS+1)); fi

run "P6 --all lists clean apps, ok-noop-diff counts as ok" --appset prod-set=v0.18.0 --all --no-diff
expect_re 'noop +tenant +Synced +ok-noop-diff'; expect_re 'clean +tenant +Synced +ok'

run "P7 unknown context" --target 1.0.0 --context nope
expect "kube context 'nope'"; expect "RC=2"

run "P8 usage errors" ; expect "give --target"; expect "RC=2"
run "P9 --appset without a revision and no --target" --appset prod-set; expect "no target for prod-set"; expect "RC=2"
run "P10 bad concurrency" --target 1 --concurrency 0; expect "--concurrency must be a positive number"; expect "RC=2"
run "P11 help" --help; expect "Usage: app-chart-preflight"; expect "RC=0"

echo; echo "$(basename "$0"): $CASES assertions, FAILS=$FAILS"; [ "$FAILS" -eq 0 ]
