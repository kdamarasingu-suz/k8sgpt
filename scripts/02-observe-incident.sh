#!/usr/bin/env bash
# Watches the cluster while the broken checkout-worker Deployment runs, so
# you can see the OOMKilled -> CrashLoopBackOff cycle happen in real time.
set -euo pipefail

echo "==> Pod status in checkout-oom-demo"
kubectl get pods -n checkout-oom-demo -o wide

echo
echo "==> Pod restart counts and last state (look for OOMKilled / Exit Code 137)"
kubectl get pods -n checkout-oom-demo -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'

echo
echo "==> Recent warning events"
kubectl get events -n checkout-oom-demo --field-selector type=Warning --sort-by=.lastTimestamp
