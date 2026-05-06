#!/usr/bin/env bash
# Orchestrator: drives static -> deploy -> smoke against the local kind cluster.
# Persists evidence to test/.last-run/ for after-the-fact auditing.
#
# Modes:
#   --audit         run pipeline, print evidence per assertion, do NOT call fix-agent
#   --self-test     run failure-injection battery (each scenario in isolation, restored after)
#   --auto          on failure, invoke `claude -p` with chart-fix subagent (requires `claude` CLI),
#                   skip diff-review pause, retry failed stage up to 3x
#   --dry-run-fix   when --auto: let fix-agent propose without applying (writes diffs to .last-run/fixes/)
#   --only=<stage>  run only one stage: static | deploy | smoke
#
# Without flags: runs the pipeline, stops on first failure, prints location of evidence
# and the suggested fix-agent invocation, exits non-zero. The interactive Claude session
# user then runs the fix-agent manually.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CHART_DIR="$(dirname "$SCRIPT_DIR")"
LAST_RUN="$SCRIPT_DIR/.last-run"
RELEASE="powersync"
NAMESPACE="powersync-test"
VALUES_TEST="$SCRIPT_DIR/values-test.yaml"
ASSERTIONS="$SCRIPT_DIR/assertions.yaml"

export LAST_RUN_DIR="$LAST_RUN"

AUDIT=0
SELF_TEST=0
AUTO=0
DRY_RUN_FIX=0
ONLY=""

for arg in "$@"; do
  case "$arg" in
    --audit) AUDIT=1 ;;
    --self-test) SELF_TEST=1 ;;
    --auto) AUTO=1 ;;
    --dry-run-fix) DRY_RUN_FIX=1 ;;
    --only=*) ONLY="${arg#--only=}" ;;
    -h|--help)
      sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

c_red()   { printf '\033[1;31m%s\033[0m' "$*"; }
c_grn()   { printf '\033[1;32m%s\033[0m' "$*"; }
c_yel()   { printf '\033[1;33m%s\033[0m' "$*"; }
c_blu()   { printf '\033[1;34m%s\033[0m' "$*"; }

log()  { printf '%s %s\n' "$(c_blu '[run]')"  "$*"; }
ok()   { printf '%s %s\n' "$(c_grn '[ok]')"  "$*"; }
fail() { printf '%s %s\n' "$(c_red '[fail]')" "$*"; }

# Dump full container logs from each PowerSync workload + the migrate Job to the
# run-artifacts dir so an operator can verify replication progress, errors, etc.
# Best-effort: ignores missing resources, captures whatever's there.
export_powersync_logs() {
  local dir="$LAST_RUN/pods"
  mkdir -p "$dir"

  # Identify the active replicator (leader) and the standby.
  # kubectl jsonpath emits names space-separated with no trailing newline, so
  # split into a bash array via word-splitting.
  local pods_str
  pods_str=$(kubectl -n "$NAMESPACE" get pods -l app=powersync-replication \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  # shellcheck disable=SC2206
  local repl_pods=($pods_str)

  # Leader detection: the leader logs "has been locked for replication with lock ID"
  # at startup (and never PSYNC_S1003); the standby logs PSYNC_S1003 at startup.
  # Use the full log buffer so the marker is found regardless of how long the pods
  # have been running.
  local leader="" standby=""
  for p in "${repl_pods[@]}"; do
    local buf
    buf=$(kubectl -n "$NAMESPACE" logs "$p" --all-containers --tail=2000 2>/dev/null)
    if echo "$buf" | grep -q "has been locked for replication with lock ID"; then
      [[ -z "$leader" ]] && leader="$p"
    elif echo "$buf" | grep -q "PSYNC_S1003"; then
      [[ -z "$standby" ]] && standby="$p"
    fi
  done
  # Fallback if both pods look identical (e.g. very fresh deploy)
  [[ -z "$leader"  && ${#repl_pods[@]} -ge 1 ]] && leader="${repl_pods[0]}"
  [[ -z "$standby" && ${#repl_pods[@]} -ge 2 ]] && {
    for p in "${repl_pods[@]}"; do
      [[ "$p" != "$leader" ]] && standby="$p" && break
    done
  }

  # API pods (combined per-pod files + a single concatenated view)
  local api_dir="$dir/api"
  mkdir -p "$api_dir"
  for p in $(kubectl -n "$NAMESPACE" get pods -l app=powersync-api -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl -n "$NAMESPACE" logs "$p" --all-containers --timestamps --tail=2000 \
      >"$api_dir/$p.log" 2>&1 || true
  done

  if [[ -n "$leader" ]]; then
    kubectl -n "$NAMESPACE" logs "$leader" --all-containers --timestamps --tail=2000 \
      >"$dir/replication-leader.log" 2>&1 || true
    echo "$leader" >"$dir/replication-leader.name"
  fi
  if [[ -n "$standby" ]]; then
    kubectl -n "$NAMESPACE" logs "$standby" --all-containers --timestamps --tail=2000 \
      >"$dir/replication-standby.log" 2>&1 || true
    echo "$standby" >"$dir/replication-standby.name"
  fi

  kubectl -n "$NAMESPACE" logs job/powersync-migrate --all-containers --timestamps --tail=2000 \
    >"$dir/migrate.log" 2>&1 || true

  # Cluster-wide context: events + a one-line workload summary
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp >"$LAST_RUN/events.log" 2>&1 || true
  {
    echo "=== pods ==="
    kubectl -n "$NAMESPACE" get pods -o wide 2>/dev/null
    echo
    echo "=== deployments ==="
    kubectl -n "$NAMESPACE" get deploy 2>/dev/null
    echo
    echo "=== jobs ==="
    kubectl -n "$NAMESPACE" get jobs 2>/dev/null
    echo
    echo "=== leader: ${leader:-<none>} ==="
    echo "=== standby: ${standby:-<none>} ==="
  } >"$LAST_RUN/workload.summary"

  log "logs exported to $dir/"
}

# --- preflight ---
preflight() {
  local need_cluster="$1"  # "yes" | "no"
  local missing=()
  local required=(helm kubeconform yq jq)
  [[ "$need_cluster" == "yes" ]] && required+=(kind kubectl docker)
  for tool in "${required[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if (( ${#missing[@]} > 0 )); then
    fail "Missing tools: ${missing[*]}"
    echo "Install with: brew install ${missing[*]}"
    return 1
  fi

  if [[ "$need_cluster" == "yes" ]]; then
    if ! kind get clusters 2>/dev/null | grep -qx "powersync-test"; then
      fail "kind cluster 'powersync-test' missing. Run ./test/setup-fixtures.sh first."
      return 1
    fi
    kubectl config use-context kind-powersync-test >/dev/null
  fi
}

# --- stage 1: static validation ---
stage_static() {
  log "stage 1: static validation"
  mkdir -p "$LAST_RUN/rendered" "$LAST_RUN/stages"
  local err_file="$LAST_RUN/stages/1-static.json"
  local rendered="$LAST_RUN/rendered/all.yaml"
  local errors=()

  if ! helm lint "$CHART_DIR" >"$LAST_RUN/helm-lint.log" 2>&1; then
    errors+=("$(jq -nc --arg msg "$(tail -20 "$LAST_RUN/helm-lint.log")" '{file:"helm-lint", line:0, msg:$msg}')")
  fi

  if ! helm template "$RELEASE" "$CHART_DIR" -f "$VALUES_TEST" \
        --namespace "$NAMESPACE" >"$rendered" 2>"$LAST_RUN/helm-template.err"; then
    errors+=("$(jq -nc --arg msg "$(cat "$LAST_RUN/helm-template.err")" '{file:"helm-template", line:0, msg:$msg}')")
  fi

  if [[ -s "$rendered" ]]; then
    if ! kubeconform -strict -ignore-missing-schemas -summary "$rendered" \
          >"$LAST_RUN/kubeconform.log" 2>&1; then
      errors+=("$(jq -nc --arg msg "$(tail -20 "$LAST_RUN/kubeconform.log")" '{file:"kubeconform", line:0, msg:$msg}')")
    fi
  fi

  local ok_flag=true
  (( ${#errors[@]} > 0 )) && ok_flag=false

  printf '{"stage":"static","ok":%s,"errors":[%s]}\n' \
    "$ok_flag" "$(IFS=,; echo "${errors[*]}")" > "$err_file"

  if $ok_flag; then ok "static validation"; return 0; fi
  fail "static validation — see $err_file"; return 1
}

# --- stage 2: deploy ---
stage_deploy() {
  log "stage 2: deploy"
  mkdir -p "$LAST_RUN/stages" "$LAST_RUN/pods"
  local out="$LAST_RUN/stages/2-deploy.json"

  if helm upgrade --install "$RELEASE" "$CHART_DIR" \
        -f "$VALUES_TEST" -n "$NAMESPACE" --take-ownership \
        --wait --timeout 5m >"$LAST_RUN/helm-deploy.log" 2>&1; then
    echo '{"stage":"deploy","ok":true,"failedPods":[]}' > "$out"
    export_powersync_logs
    ok "deploy"; return 0
  fi

  # capture state on failure
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp >"$LAST_RUN/events.log" 2>&1 || true
  local failed=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local pod_name pod_phase
    pod_name=$(echo "$line" | awk '{print $1}')
    pod_phase=$(echo "$line" | awk '{print $3}')
    [[ "$pod_phase" == "Running" || "$pod_phase" == "Completed" || "$pod_phase" == "Succeeded" ]] && continue
    kubectl -n "$NAMESPACE" describe pod "$pod_name" >"$LAST_RUN/pods/$pod_name.describe" 2>&1 || true
    kubectl -n "$NAMESPACE" logs "$pod_name" --all-containers --tail=200 >"$LAST_RUN/pods/$pod_name.log" 2>&1 || true
    failed+=("$(jq -nc \
      --arg name "$pod_name" --arg phase "$pod_phase" \
      --arg log "$(tail -50 "$LAST_RUN/pods/$pod_name.log" 2>/dev/null)" \
      '{name:$name, phase:$phase, lastLog:$log}')")
  done < <(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null)

  printf '{"stage":"deploy","ok":false,"failedPods":[%s]}\n' \
    "$(IFS=,; echo "${failed[*]}")" > "$out"
  fail "deploy — see $out"
  return 1
}

# --- stage 3: smoke ---
stage_smoke() {
  log "stage 3: smoke"
  mkdir -p "$LAST_RUN/stages"
  local out="$LAST_RUN/stages/3-smoke.json"
  local audit_arg=""
  [[ $AUDIT -eq 1 ]] && audit_arg="--audit"

  local rc=0
  bash "$SCRIPT_DIR/smoke.sh" "$ASSERTIONS" "$out" "$audit_arg" || rc=$?
  # Always re-export logs after smoke so the user can verify replication progress.
  export_powersync_logs
  if [[ $rc -eq 0 ]]; then ok "smoke"; return 0; fi
  fail "smoke — see $out"; return 1
}

# --- fix-agent invocation (auto mode) ---
invoke_fix_agent() {
  local stage_json="$1"
  if ! command -v claude >/dev/null 2>&1; then
    fail "claude CLI not in PATH; cannot auto-fix. Run interactively and ask the chart-fix subagent."
    return 2
  fi
  log "invoking chart-fix subagent (auto mode)"
  mkdir -p "$LAST_RUN/fixes"
  local before_sha
  before_sha=$(cd "$CHART_DIR" && git stash create 2>/dev/null || echo "")
  local prompt="Use the chart-fix subagent to address the failure described in $stage_json. Only edit files inside $CHART_DIR. After editing, output a one-line summary of changes."
  if (( DRY_RUN_FIX )); then
    prompt+=" DO NOT write any files; output the proposed diff only."
  fi
  claude -p "$prompt" >"$LAST_RUN/fixes/$(date +%s)-fix.log" 2>&1 || {
    fail "fix-agent returned non-zero"
    return 2
  }
  if [[ -n "$before_sha" ]]; then
    (cd "$CHART_DIR" && git diff "$before_sha" -- . >"$LAST_RUN/fixes/$(date +%s).diff" 2>/dev/null) || true
  fi
}

# --- run a single stage with auto-retry ---
run_stage_with_retry() {
  local stage="$1"
  local stage_fn="stage_$stage"
  local stage_json="$LAST_RUN/stages/$([ "$stage" = "static" ] && echo 1 || ([ "$stage" = "deploy" ] && echo 2 || echo 3))-$stage.json"
  local attempt=1
  local max=$(( AUTO ? 3 : 1 ))
  while (( attempt <= max )); do
    if "$stage_fn"; then return 0; fi
    if (( AUTO == 0 )); then
      cat <<EOF

Stage '$stage' failed.
  Evidence:        $stage_json
  Suggested fix:   ask the chart-fix subagent — "Read $stage_json and propose a chart-only fix"
  Re-run:          ./test/run.sh --only=$stage

EOF
      return 1
    fi
    log "auto-fix attempt $attempt/$max"
    invoke_fix_agent "$stage_json" || return 1
    attempt=$((attempt+1))
  done
  fail "stage '$stage' still failing after $max attempts"
  return 1
}

# --- pipeline ---
run_pipeline() {
  rm -rf "$LAST_RUN"
  mkdir -p "$LAST_RUN/stages"

  # static needs no cluster; deploy/smoke do.
  local need_cluster="no"
  [[ -z "$ONLY" || "$ONLY" == "deploy" || "$ONLY" == "smoke" ]] && need_cluster="yes"
  preflight "$need_cluster" || return 1

  if [[ -z "$ONLY" || "$ONLY" == "static" ]]; then run_stage_with_retry static || return 1; fi
  if [[ -z "$ONLY" || "$ONLY" == "deploy" ]]; then run_stage_with_retry deploy || return 1; fi
  if [[ -z "$ONLY" || "$ONLY" == "smoke" ]];  then run_stage_with_retry smoke  || return 1; fi
  ok "pipeline complete"
}

# --- self-test (failure-injection battery) ---
run_self_test() {
  log "self-test mode: running failure-injection battery"
  preflight "yes" || return 1
  local results=()
  local total=0
  local passed=0

  for inj in "$SCRIPT_DIR/injections"/*.yaml; do
    total=$((total+1))
    local id exp_stage exp_assertion
    id=$(yq -r '.id' "$inj")
    exp_stage=$(yq -r '.expected_stage' "$inj")
    exp_assertion=$(yq -r '.expected_assertion // ""' "$inj")
    log "injection: $id (expect fail at stage=$exp_stage assertion=$exp_assertion)"

    # apply patches in a worktree so we don't corrupt main checkout
    local wt="/tmp/powersync-helm-chart-inj-$id-$$"
    git -C "$CHART_DIR" worktree add -q "$wt" HEAD
    apply_injection "$inj" "$wt" || { results+=("$id|patch-fail|n/a|FAIL"); git -C "$CHART_DIR" worktree remove -f "$wt"; continue; }

    # run pipeline against the worktree (override CHART_DIR)
    local prev_chart_dir="$CHART_DIR"
    CHART_DIR="$wt"
    LAST_RUN="$wt/test/.last-run"
    export LAST_RUN_DIR="$LAST_RUN"
    VALUES_TEST="$wt/test/values-test.yaml"
    ASSERTIONS="$wt/test/assertions.yaml"

    local caught_stage="" caught_assertion=""
    if ! stage_static 2>/dev/null; then caught_stage="static"; fi
    if [[ -z "$caught_stage" ]] && ! stage_deploy 2>/dev/null; then caught_stage="deploy"; fi
    if [[ -z "$caught_stage" ]] && ! stage_smoke 2>/dev/null; then
      caught_stage="smoke"
      caught_assertion=$(jq -r '.checks[] | select(.ok==false) | .id' "$LAST_RUN/stages/3-smoke.json" 2>/dev/null | head -1)
    fi

    # restore
    CHART_DIR="$prev_chart_dir"
    LAST_RUN="$SCRIPT_DIR/.last-run"
    export LAST_RUN_DIR="$LAST_RUN"
    VALUES_TEST="$SCRIPT_DIR/values-test.yaml"
    ASSERTIONS="$SCRIPT_DIR/assertions.yaml"
    git -C "$prev_chart_dir" worktree remove -f "$wt"

    # uninstall any release the worktree run left behind
    helm uninstall "$RELEASE" -n "$NAMESPACE" --wait >/dev/null 2>&1 || true

    local verdict="FAIL"
    if [[ "$caught_stage" == "$exp_stage" ]]; then
      if [[ -z "$exp_assertion" || "$caught_assertion" == "$exp_assertion" ]]; then
        verdict="PASS"
        passed=$((passed+1))
      fi
    fi
    results+=("$id|$caught_stage|$caught_assertion|$verdict")
  done

  echo
  printf '%-32s %-10s %-32s %s\n' "INJECTION" "STAGE" "ASSERTION" "OK"
  for r in "${results[@]}"; do
    IFS='|' read -r id stage assertion ok <<<"$r"
    printf '%-32s %-10s %-32s %s\n' "$id" "$stage" "$assertion" "$ok"
  done
  echo
  log "self-test: $passed/$total passed"
  [[ $passed -eq $total ]]
}

apply_injection() {
  local inj="$1" wt="$2"
  local count
  count=$(yq -r '.patch | length' "$inj")
  for ((i=0; i<count; i++)); do
    local file find replace
    file=$(yq -r ".patch[$i].file" "$inj")
    find=$(yq -r ".patch[$i].find" "$inj")
    replace=$(yq -r ".patch[$i].replace" "$inj")
    local target="$wt/$file"
    [[ -f "$target" ]] || { fail "injection target missing: $target"; return 1; }
    # use python for safe substitution (handles multiline + no shell escaping headaches)
    python3 -c "
import sys, pathlib
p = pathlib.Path('$target')
text = p.read_text()
find = sys.stdin.read().split('---REPLACE---')[0]
replace = sys.stdin.read().split('---REPLACE---')[1] if '---REPLACE---' in sys.stdin.read() else ''
" 2>/dev/null  # noop guard
    # simpler: write find/replace to tempfiles, use python for substitution
    local fpath rpath
    fpath=$(mktemp); rpath=$(mktemp)
    printf '%s' "$find" > "$fpath"
    printf '%s' "$replace" > "$rpath"
    python3 - "$target" "$fpath" "$rpath" <<'PYEOF'
import sys, pathlib
target = pathlib.Path(sys.argv[1])
find = pathlib.Path(sys.argv[2]).read_text()
replace = pathlib.Path(sys.argv[3]).read_text()
text = target.read_text()
if find not in text:
    print(f"injection: 'find' not present in {target}", file=sys.stderr)
    sys.exit(1)
target.write_text(text.replace(find, replace, 1))
PYEOF
    rm -f "$fpath" "$rpath"
  done
}

# --- main ---
if (( SELF_TEST )); then
  run_self_test
  exit $?
fi
run_pipeline
exit $?
