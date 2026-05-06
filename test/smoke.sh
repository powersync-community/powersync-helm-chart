#!/usr/bin/env bash
# Read assertions.yaml and execute each assertion.
# Outputs a JSON report and a human-readable PASS/FAIL line per assertion.
#
# Usage: smoke.sh <assertions.yaml> <output.json> [--audit]

set -uo pipefail

ASSERTIONS="${1:?usage: smoke.sh <assertions.yaml> <output.json> [--audit]}"
OUT_JSON="${2:?usage: smoke.sh <assertions.yaml> <output.json> [--audit]}"
AUDIT="${3:-}"

NS=$(yq -r '.defaults.namespace // "powersync-test"' "$ASSERTIONS")
RELEASE=$(yq -r '.defaults.release // "powersync"' "$ASSERTIONS")

# helper: targets in assertions.yaml use the literal "powersync" name; substitute the release name.
qualify() {
  local target="$1"
  # Replace "name/powersync" or "name/powersync-..." stem with the release name.
  # BSD-sed compatible: no alternation, just basic substitution.
  awk -v rel="$RELEASE" '
    {
      sub(/^deployment\/powersync/, "deployment/" rel);
      sub(/^deploy\/powersync/,      "deploy/"      rel);
      sub(/^job\/powersync/,         "job/"         rel);
      sub(/^pod\/powersync/,         "pod/"         rel);
      sub(/^svc\/powersync/,         "svc/"         rel);
      sub(/^service\/powersync/,     "service/"     rel);
      print
    }' <<<"$target"
}

results=()
overall_ok=1

count=$(yq -r '.assertions | length' "$ASSERTIONS")
for ((i=0; i<count; i++)); do
  id=$(yq -r ".assertions[$i].id" "$ASSERTIONS")
  desc=$(yq -r ".assertions[$i].description" "$ASSERTIONS")
  type=$(yq -r ".assertions[$i].type" "$ASSERTIONS")
  target=$(yq -r ".assertions[$i].target" "$ASSERTIONS")
  target=$(qualify "$target")

  ok=0
  detail=""

  case "$type" in
    kubectl)
      jp=$(yq -r ".assertions[$i].expect.jsonpath" "$ASSERTIONS")
      eq=$(yq -r ".assertions[$i].expect.equals // \"null\"" "$ASSERTIONS")
      gte=$(yq -r ".assertions[$i].expect.gte // \"null\"" "$ASSERTIONS")
      val=$(kubectl -n "$NS" get "$target" -o "jsonpath={$jp}" 2>/dev/null || echo "")
      if [[ "$eq" != "null" && "$val" == "$eq" ]]; then
        ok=1; detail="$jp=$val"
      elif [[ "$gte" != "null" && -n "$val" && "$val" =~ ^[0-9]+$ && "$val" -ge "$gte" ]]; then
        ok=1; detail="$jp=$val (>= $gte)"
      else
        detail="$jp=$val (expected equals=$eq gte=$gte)"
      fi
      ;;
    kubectl-exec)
      mapfile -t cmd_arr < <(yq -o=json -I=0 ".assertions[$i].command" "$ASSERTIONS" | jq -r '.[]')
      pod_sel=$(kubectl -n "$NS" get "$target" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null \
        | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
      pod_name=$(kubectl -n "$NS" get pods -l "$pod_sel" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
      if [[ -z "$pod_name" ]]; then
        detail="no pod for $target (selector='$pod_sel')"
      else
        if kubectl -n "$NS" exec "$pod_name" -- "${cmd_arr[@]}" >/dev/null 2>&1; then
          ok=1; detail="exec ok in $pod_name (${cmd_arr[*]})"
        else
          detail="exec failed in $pod_name: ${cmd_arr[*]}"
        fi
      fi
      ;;
    log-grep)
      pattern=$(yq -r ".assertions[$i].pattern" "$ASSERTIONS")
      mc_eq=$(yq -r ".assertions[$i].expect.matches_count // \"null\"" "$ASSERTIONS")
      mc_gte=$(yq -r ".assertions[$i].expect.matches_count_gte // \"null\"" "$ASSERTIONS")
      logs=$(kubectl -n "$NS" logs "$target" --all-containers --tail=500 2>/dev/null || echo "")
      matches=$(printf '%s\n' "$logs" | grep -cE "$pattern" || true)
      if [[ "$mc_eq" != "null" && "$matches" -eq "$mc_eq" ]]; then
        ok=1; detail="matches=$matches (== $mc_eq)"
      elif [[ "$mc_gte" != "null" && "$matches" -ge "$mc_gte" ]]; then
        ok=1; detail="matches=$matches (>= $mc_gte)"
      else
        detail="matches=$matches (expected eq=$mc_eq gte=$mc_gte) for /$pattern/"
      fi
      ;;
    kubeconform)
      rendered_path="${LAST_RUN_DIR:-./test/.last-run}/rendered/all.yaml"
      # Render lazily if absent (e.g. when smoke.sh is invoked standalone).
      if [[ ! -f "$rendered_path" ]]; then
        chart_dir="$(cd "$(dirname "$0")/.." && pwd)"
        values_file="$(dirname "$0")/values-test.yaml"
        mkdir -p "$(dirname "$rendered_path")"
        helm template "$RELEASE" "$chart_dir" -f "$values_file" \
          --namespace "$NS" >"$rendered_path" 2>/dev/null || true
      fi
      if [[ -f "$rendered_path" ]]; then
        if kubeconform -strict -ignore-missing-schemas -summary "$rendered_path" >/dev/null 2>&1; then
          ok=1; detail="kubeconform clean ($rendered_path)"
        else
          detail=$(kubeconform -strict -ignore-missing-schemas -summary "$rendered_path" 2>&1 | tail -5 | tr '\n' ';')
        fi
      else
        detail="rendered file missing: $rendered_path"
      fi
      ;;
    helm-test)
      if helm test "$RELEASE" -n "$NS" --timeout 2m >/dev/null 2>&1; then
        ok=1; detail="helm test passed"
      else
        detail="helm test failed (see kubectl logs of test pod)"
      fi
      ;;
    *)
      detail="unknown type: $type"
      ;;
  esac

  if [[ "$ok" -eq 1 ]]; then
    if [[ "$AUDIT" == "--audit" ]]; then
      printf '  \033[1;32mPASS\033[0m  %-40s  %s\n' "$id" "$detail"
    fi
  else
    overall_ok=0
    printf '  \033[1;31mFAIL\033[0m  %-40s  %s\n' "$id" "$detail"
  fi

  results+=("$(jq -nc \
    --arg id "$id" --arg desc "$desc" --arg type "$type" \
    --arg target "$target" --arg detail "$detail" --argjson ok "$ok" \
    '{id:$id, description:$desc, type:$type, target:$target, ok:($ok==1), detail:$detail}')")
done

# write JSON report
printf '{"stage":"smoke","ok":%s,"checks":[%s]}\n' \
  "$([[ $overall_ok -eq 1 ]] && echo true || echo false)" \
  "$(IFS=,; echo "${results[*]}")" > "$OUT_JSON"

[[ $overall_ok -eq 1 ]]
