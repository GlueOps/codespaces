#!/usr/bin/env bash
# app-chart-preflight — run BEFORE bumping an ApplicationSet's GlueOps app chart targetRevision (manifests/manifest.yaml).
#
# Renders every Application of the ApplicationSets that use the app chart twice, at the current chart and at the
# target, through this cluster's own Argo CD (so no tenant repository is read), compares the pod templates and prints,
# per ApplicationSet, whether the bump is safe: the command/args items that change (old and new value), render errors,
# apps with no verdict, the pod-template diff and a verdict line. Read-only: it uses your kube context, writes nothing
# to the cluster and sends nothing anywhere. Also reachable from captain_utils → app_chart_preflight.
#
# How: one `argocd admin dashboard` on 127.0.0.1 for the run (Argo CD's API with auth off, loopback only, using your
# kube credentials), then `argocd app manifests` per app against it, a few apps at a time. Applications and
# ApplicationSets are read with kubectl. Needs: kubectl, argocd, jq, yq (mikefarah v4), curl, diff.
#
# Exit: 0 every checked ApplicationSet is ok (safe to bump); 1 a set has a diff or an error; 2 a set has no verdict,
# nothing was checked, a named set does not exist, or the run could not start.
set -euo pipefail

VERSION="1"
usage() {
    cat <<'EOF'
Usage: app-chart-preflight --target REVISION [flags]
       app-chart-preflight --appset NAME=REVISION [--appset NAME=REVISION ...] [flags]

Checks what bumping the GlueOps app chart to REVISION would change for every Application of the ApplicationSets that
use it, through this cluster's Argo CD. Run it before the bump. Read-only; uses your current kube context.

The revision's form follows how the ApplicationSet sources the chart: 0.18.0 for helm.gpkg.io or OCI,
v0.18.0 (a tag) or a branch for the chart's git repository.

Flags:
  --target REV              chart revision for every selected ApplicationSet
  --appset NAME[=REV]       check only this set; =REV also sets its target (repeatable;
                            "standalone" = app-chart Applications that no ApplicationSet generated)
  --context NAME            kube context (default: current)
  --argocd-namespace NS     where Argo CD runs (default: glueops-core)
  --concurrency N           apps checked in parallel (default: 4)
  --render-timeout SEC      limit for one render (default: 120)
  --no-diff                 leave out the pod-template diff
  --all                     also list clean and skipped apps one by one
  --wide                    do not truncate values, hints and reasons
  --no-color                no colour (also off when stdout is not a terminal, or NO_COLOR is set)
  --save FILE               also write every app's result as JSON
  -h, --help                this help

Exit code: 0 every checked set is ok; 1 a set has a diff or an error; 2 no verdict for a set, nothing checked,
a named set does not exist, or the run could not start.
EOF
}

die() { echo "app-chart-preflight: $*" >&2; exit 2; }

# ---- flags ------------------------------------------------------------------------------------------------------------
TARGET="" CONTEXT="" ARGO_NS="glueops-core" CONC=4 RENDER_TIMEOUT=120 SHOW_DIFF=1 SHOW_ALL=0 WIDE=0 COLOR=1 SAVE=""
ONLY_JSON='[]' TARGETS_JSON='{}'
need_arg() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value (see --help)"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --target) need_arg "$@"; TARGET=$2; shift 2 ;;
        --target=*) TARGET=${1#*=}; shift ;;
        --appset|--appset=*)
            if [ "$1" = --appset ]; then need_arg "$@"; v=$2; shift 2; else v=${1#*=}; shift; fi
            name=${v%%=*}; [ -n "$name" ] || die "--appset needs a name"
            ONLY_JSON=$(jq -c --arg n "$name" '. + [$n]' <<<"$ONLY_JSON")
            if [[ "$v" == *=* ]]; then
                rev=${v#*=}; [ -n "$rev" ] || die "--appset $name= has an empty revision"
                TARGETS_JSON=$(jq -c --arg n "$name" --arg r "$rev" '. + {($n): $r}' <<<"$TARGETS_JSON")
            fi ;;
        --context) need_arg "$@"; CONTEXT=$2; shift 2 ;;
        --argocd-namespace) need_arg "$@"; ARGO_NS=$2; shift 2 ;;
        --concurrency) need_arg "$@"; CONC=$2; shift 2 ;;
        --render-timeout) need_arg "$@"; RENDER_TIMEOUT=$2; shift 2 ;;
        --no-diff) SHOW_DIFF=0; shift ;;
        --all) SHOW_ALL=1; shift ;;
        --wide) WIDE=1; shift ;;
        --no-color) COLOR=0; shift ;;
        --save) need_arg "$@"; SAVE=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --version) echo "app-chart-preflight $VERSION"; exit 0 ;;
        *) die "unknown argument '$1' (see --help)" ;;
    esac
done
[[ "$CONC" =~ ^[1-9][0-9]*$ ]] || die "--concurrency must be a positive number"
[[ "$RENDER_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--render-timeout must be a positive number of seconds"
if [ -z "$TARGET" ]; then
    [ "$(jq length <<<"$ONLY_JSON")" -gt 0 ] || die "give --target REVISION, or --appset NAME=REVISION for each set to check"
    missing=$(jq -r --argjson t "$TARGETS_JSON" '[.[] | select($t[.] == null)] | join(", ")' <<<"$ONLY_JSON")
    [ -z "$missing" ] || die "no target for $missing: give --target, or NAME=REVISION"
fi
[ -t 1 ] && [ -z "${NO_COLOR+x}" ] || COLOR=0
for c in kubectl argocd jq yq curl diff timeout; do command -v "$c" >/dev/null || die "$c is required"; done

# ---- work dir, kubeconfig, local Argo CD server -------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/app-chart-preflight.XXXXXX")
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -f "$WORK/server.pid" ] && kill "$(cat "$WORK/server.pid")" 2>/dev/null || true
    rm -rf "$WORK"   # holds a copy of the kubeconfig
}
trap cleanup EXIT
trap 'echo >&2; echo "app-chart-preflight: interrupted, nothing reported" >&2; jobs -p | xargs -r kill 2>/dev/null; exit 130' INT TERM

# One context of your kubeconfig, certificates inlined, exec auth kept as is, namespace set to Argo CD's: the local
# server takes Argo CD's namespace from the context.
KCTX=${CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}
[ -n "$KCTX" ] || die "no current kube context: pass --context or run kubectl config use-context"
kubectl config view --raw --minify --flatten --context "$KCTX" > "$WORK/kubeconfig" 2>"$WORK/kc.err" \
    || die "kube context '$KCTX': $(tail -1 "$WORK/kc.err")"
chmod 600 "$WORK/kubeconfig"
export KUBECONFIG="$WORK/kubeconfig"
kubectl config set-context --current --namespace="$ARGO_NS" >/dev/null
ACD_CONFIG="$WORK/argocd-config"   # never touch your own argocd login state

free_port() {
    local p
    for _ in $(seq 1 50); do
        p=$(( 20000 + RANDOM % 20000 ))
        (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || { echo "$p"; return 0; }
    done
    return 1
}
PORT=$(free_port) || die "no free local port for the Argo CD server"

start_server() {
    argocd admin dashboard --port "$PORT" --address 127.0.0.1 >"$WORK/server.log" 2>&1 &
    echo $! > "$WORK/server.pid"
    for _ in $(seq 1 180); do
        curl -sf -m 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && return 0
        kill -0 "$(cat "$WORK/server.pid")" 2>/dev/null || break
        sleep 0.5
    done
    echo "app-chart-preflight: the local Argo CD server did not start:" >&2
    tail -5 "$WORK/server.log" >&2
    return 1
}

# Called by a worker after a lost connection: restart the server once (the lock keeps workers from racing).
ensure_server() {
    curl -sf -m 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && return 0
    (
        flock 9
        curl -sf -m 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && exit 0
        kill "$(cat "$WORK/server.pid")" 2>/dev/null || true
        sleep 1
        start_server
    ) 9>"$WORK/server.lock"
}

# ---- one app ----------------------------------------------------------------------------------------------------------
TRANSIENT='bind: address already in use|dial tcp 127\.0\.0\.1:[0-9]+: connect: connection refused|error upgrading connection|port forward|code = Unavailable|lost connection to pod|error reading from server|connection reset by peer'
CHART_ERROR='every item must be a string|must be a list of strings|got (map|null|list|slice)\b'

# render APP OUT ERR [revision args...] — argocd app manifests with a timeout and two retries on a lost connection.
render() {
    local app=$1 out=$2 err=$3 rc attempt
    shift 3
    for attempt in 1 2 3; do
        rc=0
        timeout "$RENDER_TIMEOUT" argocd --config "$ACD_CONFIG" app manifests "$app" "$@" \
            --server "127.0.0.1:$PORT" --plaintext >"$out" 2>"$err" || rc=$?
        if [ "$rc" = 0 ] || [ "$rc" = 124 ] || ! grep -qE "$TRANSIENT" "$err" || [ "$attempt" = 3 ]; then
            return "$rc"
        fi
        sleep $(( attempt * 3 ))
        ensure_server || true
    done
}

# The reason from argocd's stderr: the last JSON log line's msg (which can span lines), else the last plain lines.
stderr_raw() {
    local m
    m=$(jq -R -s -r '[split("\n")[] | fromjson? | objects | .msg // empty] | last // empty' "$1" 2>/dev/null)
    if [ -z "$m" ]; then m=$(grep -v '^[[:space:]]*{' "$1" | grep -v '^[[:space:]]*$' | tail -3 | paste -sd'|' - | sed 's/|/ | /g'); fi
    printf '%s' "${m:0:1000}"
}
stderr_reason() { stderr_raw "$1" | tr '\n\t' '  '; }

# The chart's own sentence for a null/map item, without the helm wrapping: the line after "execution error at (...): ".
chart_reason() {
    local r
    r=$(stderr_raw "$1")
    if [[ "$r" == *"execution error at ("* ]]; then r=${r#*execution error at (}; r=${r#*): }; r=${r%%$'\n'*}; fi
    printf '%s' "$r" | tr '\n\t' '  '
}

# Pod templates of a rendered stream: [{key: "Kind/name", tpl: {...}}].
templates() {
    yq -o=json -I=0 '.' "$1" 2>/dev/null | jq -c '
        select(type == "object" and (.kind | type) == "string" and (.metadata.name | type) == "string")
        | (if .kind == "CronJob" then .spec.jobTemplate.spec.template else .spec.template end) as $t
        | select(($t | type) == "object")
        | {key: (.kind + "/" + .metadata.name), tpl: $t}' | jq -s -c .
}

# Compares two template lists. Classification follows the 0.18.0 table (GlueOps/project-template-helm-chart-app#147).
COMPARE=$(cat <<'JQ'

def tomap: map({(.key): .tpl}) | add // {};
def chartkeys: ["helm.sh/chart", "glueops.dev/chart", "app.kubernetes.io/version"];
def nochart:
  if (.metadata | type) == "object" then
    reduce ("labels", "annotations") as $f (.;
      if (.metadata[$f] | type) == "object" then
        .metadata[$f] |= with_entries(select(.key as $k | chartkeys | index($k) | not))
        | if .metadata[$f] == {} then del(.metadata[$f]) else . end
      else . end)
    | if .metadata == {} then del(.metadata) else . end
  else . end;
def nocmdargs: reduce ("containers", "initContainers") as $c (.;
  if (.spec[$c] | type) == "array" then .spec[$c] |= map(del(.command, .args)) else . end);
def describe: if . == null then "null" else type end | {"array":"list","object":"map","boolean":"boolean","number":"number","null":"null"}[.] // .;
def trimspace: sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "");
def classify($o; $n; $oabs; $nabs):
  if $oabs or $nabs then {category: "length_changed", impact: "roll", hint: "the list has a different number of items at the target revision; inspect both sides"}
  elif ($o == null and $n == "") or ($o == "" and $n == null) then {category: "null_item", impact: "none", hint: "the API server stored \"\" for both; no rollout"}
  elif ($o | type) == "string" and ($n | type) == "string" then
    if $n == ("\"" + $o + "\"") or $n == ("'" + $o + "'") then {category: "double_quoted", impact: "break", hint: "the item is wrapped in a second pair of quotes; 0.17.x stripped them, the target keeps them - remove the outer quotes before upgrading"}
    elif ($n | startswith($o + " #")) then {category: "comment_truncated", impact: "roll", hint: "' #' was treated as a YAML comment; the full value is delivered from the target revision"}
    elif $o == "" and ($n | startswith("#")) then {category: "leading_hash", impact: "roll", hint: "a leading '#' emptied the item; the full value is delivered from the target revision"}
    elif ($n | trimspace) == $o and $n != $o then {category: "padded", impact: "roll", hint: "leading/trailing spaces are preserved from the target revision"}
    else {category: "other", impact: "roll", hint: "the item renders differently at the target revision; inspect both sides"} end
  elif ($n | type) == "string" then {category: "retyped", impact: "roll", hint: ("0.17.x rendered this item as a YAML " + ($o | describe) + "; the target delivers the string")}
  else {category: "other", impact: "roll", hint: "the item renders differently at the target revision; inspect both sides"} end;
def byname: map(select(type == "object") | {(.name // ""): .}) | add // {};
($cur[0] | tomap) as $C | ($new[0] | tomap) as $N
| ([$C, $N] | map(keys) | add | unique) as $keys
| {
  findings: [
    $keys[] as $k
    | ("containers", "initContainers") as $ct
    | (($C[$k].spec[$ct] // []) | byname) as $oc | (($N[$k].spec[$ct] // []) | byname) as $nc
    | ([$oc, $nc] | map(keys) | add | unique)[] as $name
    | ("command", "args") as $f
    | ($oc[$name][$f] // []) as $ol | ($nc[$name][$f] // []) as $nl
    | range(0; ([($ol | length), ($nl | length)] | max)) as $i
    | ($i >= ($ol | length)) as $oabs | ($i >= ($nl | length)) as $nabs
    | select($oabs or $nabs or $ol[$i] != $nl[$i])
    | {resource: $k, container: (if $ct == "initContainers" then "init:" + $name else $name end), field: ($f + "[" + ($i | tostring) + "]"),
       old: (if $oabs then "(absent)" else ($ol[$i] | tojson) end), new: (if $nabs then "(absent)" else ($nl[$i] | tojson) end)}
       + classify($ol[$i]; $nl[$i]; $oabs; $nabs)
  ],
  other: [$keys[] as $k | select(($C[$k] // {} | nochart | nocmdargs) != ($N[$k] // {} | nochart | nocmdargs)) | $k],
  diffkeys: [$keys[] as $k | select(($C[$k] // {} | nochart) != ($N[$k] // {} | nochart)) | $k],
  clean: {cur: ($C | map_values(nochart)), new: ($N | map_values(nochart))}
}
JQ
)

# check_app ITEM_JSON — prints the app's result object.
check_app() {
    local item=$1 app set id dir rc_cur rc_new status reason="" target cur
    app=$(jq -r .app <<<"$item"); set=$(jq -r .set <<<"$item"); id=$(jq -r .id <<<"$item")
    target=$(jq -r .target <<<"$item"); cur=$(jq -r .rev <<<"$item")
    dir="$WORK/apps/$id"; mkdir -p "$dir"
    local -a revargs
    if [ "$(jq -r .single <<<"$item")" = true ]; then revargs=(--revision "$target")
    else revargs=(--revisions "$target" --source-positions "$(jq -r .pos <<<"$item")"); fi
    rc_cur=0; render "$app" "$dir/cur.yaml" "$dir/cur.err" || rc_cur=$?
    rc_new=0; render "$app" "$dir/new.yaml" "$dir/new.err" "${revargs[@]}" || rc_new=$?
    result() { jq -c --arg s "$1" --arg r "$2" '. + {status: $s, reason: (if $r == "" then null else $r end), findings: [], other: []}' <<<"$item"; }
    if [ "$rc_new" != 0 ] && [ "$rc_new" != 124 ] && grep -qE "$CHART_ERROR" "$dir/new.err"; then result error "$(chart_reason "$dir/new.err")"; return; fi
    if [ "$rc_cur" = 124 ]; then result unknown "argocd app manifests (current) timed out"; return; fi
    if [ "$rc_cur" != 0 ]; then result unknown "argocd app manifests (current) failed: $(stderr_reason "$dir/cur.err")"; return; fi
    if [ "$rc_new" = 124 ]; then result unknown "argocd app manifests (target) timed out"; return; fi
    if [ "$rc_new" != 0 ]; then result unknown "argocd app manifests (target) failed: $(stderr_reason "$dir/new.err")"; return; fi
    templates "$dir/cur.yaml" > "$dir/cur.json" && templates "$dir/new.yaml" > "$dir/new.json" \
        || { result unknown "could not parse the rendered manifests"; return; }
    jq -n -c --slurpfile cur "$dir/cur.json" --slurpfile new "$dir/new.json" "$COMPARE" > "$dir/cmp.json" \
        || { result unknown "could not compare the rendered manifests"; return; }
    status=$(jq -r 'if any(.findings[]; .impact == "break" or .impact == "roll") then "diff"
                    elif (.findings | length) > 0 then "ok-noop-diff" else "ok" end' "$dir/cmp.json")
    if [ "$status" = diff ] && [ "$SHOW_DIFF" = 1 ]; then
        local k f=0
        while IFS= read -r k; do
            jq --arg k "$k" '.clean.cur[$k] // {}' "$dir/cmp.json" | yq -P 'sort_keys(..)' > "$dir/a.yaml"
            jq --arg k "$k" '.clean.new[$k] // {}' "$dir/cmp.json" | yq -P 'sort_keys(..)' > "$dir/b.yaml"
            diff -u --label "$k @ $cur" --label "$k @ $target" "$dir/a.yaml" "$dir/b.yaml" >> "$dir/diff.txt" || true
            f=1
        done < <(jq -r '.diffkeys[]' "$dir/cmp.json")
        [ "$f" = 1 ] || true
    fi
    jq -c --arg s "$status" --slurpfile c "$dir/cmp.json" '. + {status: $s, reason: null, findings: $c[0].findings, other: $c[0].other}' <<<"$item"
}

# ---- discovery --------------------------------------------------------------------------------------------------------
echo "Checking context $KCTX (Argo CD in $ARGO_NS)..." >&2
kubectl get applicationsets.argoproj.io -n "$ARGO_NS" -o json > "$WORK/appsets.json" 2>"$WORK/k.err" \
    || die "cannot list ApplicationSets in $ARGO_NS: $(tail -1 "$WORK/k.err")"
kubectl get applications.argoproj.io -n "$ARGO_NS" -o json > "$WORK/apps.json" 2>"$WORK/k.err" \
    || die "cannot list Applications in $ARGO_NS: $(tail -1 "$WORK/k.err")"

PLAN=$(cat <<'JQ'

def detect:
  ((.repoURL // "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")) as $r | (.chart // "") as $c
  | if $c == "app" and ($r | test("^https?://(incubating-)?helm\\.gpkg\\.io/project-template/?$"; "i")) then "helm"
    elif $c == "app" and ($r | test("^(oci://)?[a-z0-9.-]+(:[0-9]+)?/glueops/project-template-helm-chart-app/?$"; "i")) then "oci"
    elif $c == "" and ($r | test("^oci://[a-z0-9.-]+(:[0-9]+)?/glueops/project-template-helm-chart-app/app/?$"; "i")) then "oci"
    elif $c == "" and ($r | test("^(https?://|git@|ssh://)?[^/]*github\\.com[/:]glueops/project-template-helm-chart-app(\\.git)?/?$"; "i")) then "git"
    else null end;
def values($s): [$s.helm.valueFiles[]? | strings | sub("^\\$[^/]+/"; "")];
def chartsrc:
  if (.sources | type) == "array" then
    [.sources | to_entries[] | (.value | detect) as $t | select($t != null)
     | {type: $t, single: false, pos: (.key + 1), rev: (.value.targetRevision // ""), values: values(.value)}] | .[0]
  elif (.source | type) == "object" then
    (.source | detect) as $t | if $t then {type: $t, single: true, pos: 1, rev: (.source.targetRevision // ""), values: values(.source)} else null end
  else null end;
def semver: test("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$");
def validate($type; $t):
  if $type == "git" then (if ($t | semver) then "target \"\($t)\" looks like a chart version; a git-sourced chart needs a git ref such as v\($t)" else "" end)
  elif ($t | semver) then ""
  elif ($t | ltrimstr("v") | semver) then "target \"\($t)\" is not a chart version; a \($type)-sourced chart needs X.Y.Z (e.g. \($t | ltrimstr("v")))"
  else "target \"\($t)\" is not a chart version; a \($type)-sourced chart needs X.Y.Z" end;
($only | length > 0) as $filtered
| def wanted($n): ($filtered | not) or any($only[]; . == $n);
[$sets[0].items[] | {name: .metadata.name, chart: (.spec.template.spec | chartsrc)} | select(.chart != null)] as $all
| [$all[] | select(wanted(.name))] as $kept
| ([$all[].name] - [$kept[].name]) as $excluded
| [ ($kept[] | {name, source_type: .chart.type, current: .chart.rev, has: (.name as $n | $targets | has($n)), t: ($targets[.name] // $target)}),
    (select(wanted("standalone")) | {name: "standalone", source_type: null, current: null, has: ($targets | has("standalone")), t: ($targets["standalone"] // $target)}) ]
  | map(. + {target: (if .t == "" then null else .t end),
             skip: (if .t != "" then null elif .has then "skipped by targets override" else "no target revision configured" end),
             unknown: (if .t != "" and .source_type != null then (validate(.source_type; .t) | if . == "" then null else . end) else null end)}
        | del(.t, .has)) as $groups
| ($groups | map({(.name): .}) | add // {}) as $G
| [ $apps[0].items[]
    | (.metadata.labels["argocd.argoproj.io/application-set-name"]
       // ([.metadata.ownerReferences[]? | select(.kind == "ApplicationSet") | .name] | .[0]) // "") as $owner
    | (.spec | chartsrc) as $chart
    | (if $G[$owner] then $owner elif $owner != "" and any($excluded[]; . == $owner) then "#excluded"
       elif $chart != null then (if $G["standalone"] then "standalone" else "#excluded" end) else "#ignored" end) as $set
    | {set: $set, app: .metadata.name, ns: (.spec.destination.namespace // .metadata.namespace), sync: (.status.sync.status // null),
       type: $chart.type, single: $chart.single, pos: $chart.pos, rev: ($chart.rev // ""), values: ($chart.values // []),
       target: ($G[$set].target // null)} ] as $items
| {
  groups: $groups,
  ignored: ([$items[] | select(.set == "#ignored")] | length),
  excluded: ([$items[] | select(.set == "#excluded")] | length),
  missing: [$only[] | . as $x | select($x != "standalone" and (any($all[]; .name == $x) | not))],
  apps: [ $items[] | select(.set | startswith("#") | not) | $G[.set] as $g
    | if .type == null then . + {status: "skipped", reason: "source is not the app chart"}
      elif $g.skip then . + {status: "skipped", reason: $g.skip}
      elif $g.unknown then . + {status: "unknown", reason: $g.unknown}
      elif $g.source_type == null and (validate(.type; $g.target) != "") then . + {status: "skipped", reason: validate(.type; $g.target)}
      elif $g.current != null and .rev != $g.current then . + {status: "unknown", reason: "revision drift from ApplicationSet: app pins \"\(.rev)\", template pins \"\($g.current)\""}
      else . + {status: "check"} end ]
  | to_entries | map(.value + {id: (.key | tostring)})
}
JQ
)
jq -n -c --slurpfile sets "$WORK/appsets.json" --slurpfile apps "$WORK/apps.json" --arg target "$TARGET" \
    --argjson targets "$TARGETS_JSON" --argjson only "$ONLY_JSON" "$PLAN" > "$WORK/plan.json" \
    || die "could not read the ApplicationSets and Applications"

# ---- run ----------------------------------------------------------------------------------------------------------------
mkdir -p "$WORK/apps" "$WORK/results"
jq -c '.apps[] | select(.status != "check") | . + {findings: [], other: []}' "$WORK/plan.json" > "$WORK/results/precomputed.jsonl"
jq -c '.apps[] | select(.status == "check")' "$WORK/plan.json" > "$WORK/todo.jsonl"
TOTAL=$(wc -l < "$WORK/todo.jsonl")
START=$(date +%s)
progress() { if [ -t 2 ]; then printf '\rchecked %d/%d apps' "$1" "$TOTAL" >&2; [ "$1" != "$TOTAL" ] || printf '\r\033[K' >&2
             elif [ $(( $1 * 10 / TOTAL )) != $(( ($1 - 1) * 10 / TOTAL )) ] || [ "$1" = 1 ] || [ "$1" = "$TOTAL" ]; then
                 echo "checked $1/$TOTAL apps" >&2; fi; }
if [ "$TOTAL" -gt 0 ]; then
    start_server || exit 2
    SERVER_PID=$(cat "$WORK/server.pid")
    running=0 done_n=0
    while IFS= read -r item; do
        id=$(jq -r .id <<<"$item")
        ( check_app "$item" > "$WORK/results/$id.json" 2>"$WORK/apps/$id.log" || true ) &
        running=$((running + 1))
        if [ "$running" -ge "$CONC" ]; then wait -n || true; running=$((running - 1)); done_n=$((done_n + 1)); progress "$done_n"; fi
    done < "$WORK/todo.jsonl"
    while [ "$running" -gt 0 ]; do wait -n || true; running=$((running - 1)); done_n=$((done_n + 1)); progress "$done_n"; done
fi
# An app whose worker died without a result still gets a line.
while IFS= read -r item; do
    id=$(jq -r .id <<<"$item")
    [ -s "$WORK/results/$id.json" ] || jq -c '. + {status: "unknown", reason: "the check did not finish", findings: [], other: []}' <<<"$item" > "$WORK/results/$id.json"
done < "$WORK/todo.jsonl"
cat "$WORK"/results/*.json* | jq -s -c 'sort_by(.set, .app)' > "$WORK/results.json"
ELAPSED=$(( $(date +%s) - START ))

# ---- report -----------------------------------------------------------------------------------------------------------
SUMMARY=$(cat <<'JQ'

def rank: {"skipped": -1, "ok": 0, "ok-noop-diff": 0, "unknown": 1, "diff": 2, "error": 3}[.];
$plan[0].groups as $groups | $res[0] as $res
| [ $groups[] | . as $g | [$res[] | select(.set == $g.name)] as $a
    | ($a | map(.status | rank) | max // -1) as $m
    | $g + {apps: ($a | length),
            ok: ([$a[] | select(.status == "ok" or .status == "ok-noop-diff")] | length),
            diff: ([$a[] | select(.status == "diff")] | length), error: ([$a[] | select(.status == "error")] | length),
            unknown_n: ([$a[] | select(.status == "unknown")] | length), skipped_n: ([$a[] | select(.status == "skipped")] | length),
            status: (if $g.skip then "skipped" else ({"-1": "skipped", "0": "ok", "1": "unknown", "2": "diff", "3": "error"}[$m | tostring]) end)} ]
| sort_by(.name == "standalone", .name)
JQ
)
jq -n -c --slurpfile plan "$WORK/plan.json" --slurpfile res "$WORK/results.json" "$SUMMARY" > "$WORK/sets.json"

if [ "$COLOR" = 1 ]; then B=$'\033[1m' R=$'\033[0m' RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' MAG=$'\033[35m' DIM=$'\033[2m' CYN=$'\033[36m'
else B="" R="" RED="" GRN="" YEL="" MAG="" DIM="" CYN=""; fi

# tbl INDENT COLOURED_COLUMN — TSV (header first) to aligned columns; the named column is coloured by value.
tbl() {
    awk -F'\t' -v ind="$1" -v cc="${2:-0}" -v color="$COLOR" '
    function paint(v) {
        if (!color) return v
        if (v == "ok" || v == "ok-noop-diff") return "\033[32m" v "\033[0m"
        if (v == "diff" || v == "roll") return "\033[33m" v "\033[0m"
        if (v == "error" || v == "break") return "\033[31;1m" v "\033[0m"
        if (v == "unknown") return "\033[35m" v "\033[0m"
        if (v == "skipped" || v == "none") return "\033[2m" v "\033[0m"
        return v
    }
    { for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } n[NR] = NF; rows = NR }
    END {
        for (r = 1; r <= rows; r++) {
            line = ind
            for (i = 1; i <= n[r]; i++) {
                v = c[r, i]; pad = sprintf("%" (w[i] - length(v)) "s", "")
                if (r == 1 && color) v = "\033[1m" v "\033[0m"; else if (i == cc) v = paint(v)
                line = line v (i < n[r] ? pad "  " : "")
            }
            sub(/ +$/, "", line); print line
        }
    }'
}

CAPTAIN=$(basename "$PWD"); [[ "$CAPTAIN" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] || CAPTAIN=$KCTX
ACD_VERSION=$(argocd version --client --short 2>/dev/null | head -1 | sed 's/^argocd: //')
TARGET_SHOWN=${TARGET:-per ApplicationSet}
NSETS=$(jq length "$WORK/sets.json"); NAPPS=$(jq '[.[].apps] | add // 0' "$WORK/sets.json")
printf '%sApp chart preflight%s  %s  context %s  argocd %s\n' "$B" "$R" "$CAPTAIN" "$KCTX" "$ACD_VERSION"
printf 'Target %s · %s ApplicationSets · %s apps checked in %ss\n\n' "$TARGET_SHOWN" "$NSETS" "$NAPPS" "$ELAPSED"

if [ "$NSETS" = 0 ]; then
    echo "No ApplicationSet or Application uses the app chart."
else
    { printf 'APPLICATIONSET\tSOURCE\tCURRENT\tTARGET\tSTATUS\tAPPS\tOK\tDIFF\tERROR\tUNKNOWN\tSKIPPED\n'
      jq -r '.[] | [.name, (.source_type // "-"), (.current // "-"), (.target // "-"), .status, .apps, .ok, .diff, .error, .unknown_n, .skipped_n] | map(tostring) | join("\t")' "$WORK/sets.json"
    } | tbl "" 5
fi

# shellcheck disable=SC2016   # jq helpers
JQ_CUT='def cut($n): if $wide == 1 or length <= $n then . else .[0:$n - 3] + "..." end;'
meaning() { case "$1" in ok) echo "safe to bump";; diff) echo "bumping changes these pods; fix the values first, or accept the rollout";;
            error) echo "the target does not render for these apps; fix the values first";; unknown) echo "no verdict for these apps; check the reason and run again";;
            *) echo "not checked";; esac; }
apps_of() { jq -c --arg s "$1" --arg st "$2" '[.[] | select(.set == $s and (.status as $x | $st | split(",") | index($x)))]' "$WORK/results.json"; }

while IFS= read -r set_json; do
    name=$(jq -r .name <<<"$set_json"); st=$(jq -r .status <<<"$set_json")
    changed=$(apps_of "$name" diff); errs=$(apps_of "$name" error); unk=$(apps_of "$name" unknown)
    clean=$(apps_of "$name" "ok,ok-noop-diff"); skipped=$(apps_of "$name" skipped)
    reason=$(jq -r '.skip // .unknown // empty' <<<"$set_json")
    n_att=$(jq -n --argjson a "$changed" --argjson b "$errs" --argjson c "$unk" '($a + $b + $c) | length')
    [ "$n_att" -gt 0 ] || [ -n "$reason" ] || [ "$SHOW_ALL" = 1 ] || [ "$(jq length <<<"$skipped")" -gt 0 ] || continue
    case "$st" in ok) c=$GRN;; diff) c=$YEL;; error) c=$RED$B;; unknown) c=$MAG;; *) c=$DIM;; esac
    printf '\n%s%s%s — %s%s%s: %s\n' "$B" "$name" "$R" "$c" "$(tr '[:lower:]' '[:upper:]' <<<"$st")" "$R" "$(meaning "$st")"
    [ -z "$reason" ] || printf '  reason: %s\n' "$reason"
    if [ "$(jq length <<<"$changed")" -gt 0 ]; then
        printf '\n  Changes (command/args items, current chart -> target)\n'
        { printf 'APP\tSYNC\tRESOURCE\tCONTAINER\tFIELD\tIMPACT\tOLD\tNEW\tHINT\n'
          jq -r --argjson wide "$WIDE" "$JQ_CUT"'
            .[] | . as $a | .findings | to_entries[] | .key as $i | .value
            | [(if $i == 0 then $a.app else "" end), (if $i == 0 then ($a.sync // "-") else "" end), .resource, .container, .field, .impact,
               (.old | cut(40)), (.new | cut(40)), (.hint | cut(60))] | map(tostring | gsub("[\t\n]"; " ")) | join("\t")' <<<"$changed"
        } | tbl "  " 6
        jq -r '.[] | "  \(.app) (namespace \(.ns)) values: \(if (.values | length) > 0 then .values | join(", ") else "none listed (inline helm values in the Application)" end)"
                     + (if (.other | length) > 0 then "; also changes other pod-template fields in \(.other | length) resource(s), see the diff" else "" end)' <<<"$changed"
    fi
    for pair in "Render errors:$errs" "No verdict:$unk"; do
        title=${pair%%:*}; list=${pair#*:}
        [ "$(jq length <<<"$list")" -gt 0 ] || continue
        printf '\n  %s\n' "$title"
        { printf 'APP\tNAMESPACE\tSYNC\tREASON\n'
          jq -r --argjson wide "$WIDE" "$JQ_CUT"'.[] | [.app, .ns, (.sync // "-"), ((.reason // "") | cut(110))] | map(tostring | gsub("[\t\n]"; " ")) | join("\t")' <<<"$list"
        } | tbl "  "
    done
    if [ "$SHOW_ALL" = 1 ] && [ "$(jq length <<<"$clean")" -gt 0 ]; then
        printf '\n  Clean\n'
        { printf 'APP\tNAMESPACE\tSYNC\tSTATUS\n'; jq -r '.[] | [.app, .ns, (.sync // "-"), .status] | join("\t")' <<<"$clean"; } | tbl "  " 4
    fi
    if [ "$(jq length <<<"$skipped")" -gt 0 ]; then
        if [ "$SHOW_ALL" = 1 ]; then
            printf '\n  Skipped\n'
            { printf 'APP\tNAMESPACE\tSYNC\tREASON\n'; jq -r '.[] | [.app, .ns, (.sync // "-"), (.reason // "")] | map(gsub("[\t\n]"; " ")) | join("\t")' <<<"$skipped"; } | tbl "  "
        else
            echo
            jq -r --argjson wide "$WIDE" "$JQ_CUT"'group_by(.reason) | .[] | "  \(length) skipped: \(.[0].reason // "skipped" | cut(110))"' <<<"$skipped" \
                | while IFS= read -r l; do printf '%s%s%s\n' "$DIM" "$l" "$R"; done
        fi
    fi
done < <(jq -c '.[]' "$WORK/sets.json")

if [ "$SHOW_DIFF" = 1 ]; then
    first=1
    while IFS=$'\t' read -r id set app; do
        f="$WORK/apps/$id/diff.txt"; [ -s "$f" ] || continue
        if [ "$first" = 1 ]; then printf '\n%sPod template diffs (current chart -> target, chart-version labels left out)%s\n' "$B" "$R"; first=0; fi
        printf '\n%s%s / %s%s\n' "$B" "$set" "$app" "$R"
        while IFS= read -r l; do
            case "$l" in
                ---*|+++*) printf '%s%s%s\n' "$B" "$l" "$R" ;;
                @@*) printf '%s%s%s\n' "$CYN" "$l" "$R" ;;
                +*) printf '%s%s%s\n' "$GRN" "$l" "$R" ;;
                -*) printf '%s%s%s\n' "$RED" "$l" "$R" ;;
                *) printf '%s\n' "$l" ;;
            esac
        done < "$f"
    done < <(jq -r '.[] | select(.status == "diff") | [.id, .set, .app] | @tsv' "$WORK/results.json")
fi

printf '\n%sVerdict%s\n' "$B" "$R"
stop=$(jq -r '[.[] | select(.status == "diff" or .status == "error") | "\(.name) (\([(if .diff > 0 then "\(.diff) diff" else empty end), (if .error > 0 then "\(.error) error" else empty end)] | join(", ")))"] | join(", ")' "$WORK/sets.json")
none=$(jq -r '[.[] | select(.status == "unknown") | "\(.name) (\(.unknown_n) unknown)"] | join(", ")' "$WORK/sets.json")
safe=$(jq -r '[.[] | select(.status == "ok") | .name] | join(", ")' "$WORK/sets.json")
skip=$(jq -r '[.[] | select(.status == "skipped") | .name] | join(", ")' "$WORK/sets.json")
[ -z "$stop" ] || printf '  %sDo NOT bump:%s %s\n' "$RED$B" "$R" "$stop"
[ -z "$none" ] || printf '  %sNo verdict, run again:%s %s\n' "$MAG" "$R" "$none"
[ -z "$safe" ] || printf '  %sSafe to bump:%s %s\n' "$GRN" "$R" "$safe"
[ -z "$skip" ] || printf '  %sNot checked:%s %s\n' "$DIM" "$R" "$skip"
[ "$NSETS" != 0 ] || echo "  nothing to check"

missing=$(jq -r '.missing | join(", ")' "$WORK/plan.json")
[ -z "$missing" ] || echo "app-chart-preflight: no ApplicationSet that uses the app chart is named $missing" >&2

if [ -n "$SAVE" ]; then
    jq -n --slurpfile sets "$WORK/sets.json" --slurpfile apps "$WORK/results.json" \
        --arg captain "$CAPTAIN" --arg context "$KCTX" --arg target "$TARGET" --arg argocd "$ACD_VERSION" \
        '{captain: $captain, context: $context, target: (if $target == "" then null else $target end), argocd_cli: $argocd,
          appsets: $sets[0], apps: ($apps[0] | map(del(.id)))}' > "$SAVE" && echo "Results saved to $SAVE" >&2
fi

code=$(jq -r 'if any(.[]; .status == "diff" or .status == "error") then 1 elif any(.[]; .status == "unknown") then 2
              elif any(.[]; .status == "ok") then 0 else 2 end' "$WORK/sets.json")
[ -z "$missing" ] || [ "$code" != 0 ] || code=2
exit "$code"
