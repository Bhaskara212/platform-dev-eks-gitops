#!/usr/bin/env bash
# Post-deploy validation. Opens temporary port-forwards and checks the stack end to end.
set -uo pipefail
NS=monitoring; FAIL=0
chk(){ if eval "$2" >/dev/null 2>&1; then echo "[ok]   $1"; else echo "[FAIL] $1"; FAIL=1; fi; }

echo "== Argo CD"
kubectl -n argocd get applications.argoproj.io
chk "all Applications Synced+Healthy" \
 "[ \$(kubectl -n argocd get applications.argoproj.io -o json | jq '[.items[]|select(.status.sync.status!=\"Synced\" or .status.health.status!=\"Healthy\")]|length') -eq 0 ]"

echo "== Pods / PVCs"
kubectl -n $NS get pods,pvc
chk "no non-Running pods in $NS" "[ -z \"\$(kubectl -n $NS get pods --no-headers | grep -v -E 'Running|Completed')\" ]"
chk "all PVCs Bound" "[ -z \"\$(kubectl -n $NS get pvc --no-headers | grep -v Bound)\" ]"
chk "node-exporter on every node" \
 "[ \$(kubectl -n $NS get ds -l app.kubernetes.io/name=prometheus-node-exporter -o jsonpath='{.items[0].status.numberReady}') -eq \$(kubectl get nodes --no-headers | wc -l) ]"
chk "kube-state-metrics Available" "kubectl -n $NS wait deploy -l app.kubernetes.io/name=kube-state-metrics --for=condition=Available --timeout=60s"

echo "== Prometheus targets (port-forward 9090)"
kubectl -n $NS port-forward svc/kps-prometheus 9090:9090 >/dev/null 2>&1 & PF1=$!
kubectl -n $NS port-forward svc/kps-alertmanager 9093:9093 >/dev/null 2>&1 & PF2=$!
kubectl -n $NS port-forward svc/grafana 3000:80 >/dev/null 2>&1 & PF3=$!
trap 'kill $PF1 $PF2 $PF3 2>/dev/null' EXIT; sleep 6

curl -s localhost:9090/api/v1/targets | jq -r '.data.activeTargets|group_by(.scrapePool)[]|"\(.[0].scrapePool)  up=\(map(select(.health=="up"))|length)/\(length)"'
chk "no DOWN targets" "[ \$(curl -s localhost:9090/api/v1/targets | jq '[.data.activeTargets[]|select(.health!=\"up\")]|length') -eq 0 ]"
chk "node-exporter metric present" "[ \$(curl -s 'localhost:9090/api/v1/query?query=count(node_cpu_seconds_total)' | jq -r '.data.result[0].value[1]') -gt 0 ]"
chk "kube-state-metrics metric present" "[ \$(curl -s 'localhost:9090/api/v1/query?query=count(kube_pod_info)' | jq -r '.data.result[0].value[1]') -gt 0 ]"
chk "Watchdog alert firing (alert pipeline alive)" "curl -s localhost:9093/api/v2/alerts | jq -e '.[]|select(.labels.alertname==\"Watchdog\")'"
chk "Grafana healthy" "curl -s localhost:3000/api/health | jq -e '.database==\"ok\"'"

[ $FAIL -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
