#!/usr/bin/env bash
# The actual remediation, GitOps-style: copy the corrected manifests over the
# live path, commit, and push. ArgoCD (installed with automated+selfHeal sync
# in scripts/01-bootstrap-cluster.sh) reconciles the cluster automatically on
# its next poll, or you can force it immediately with `argocd app sync`.
set -euo pipefail

cp manifests/reference-fixed/*.yaml manifests/live/

git add manifests/live
git commit -m "fix(checkout-worker): add resources.requests/limits sized to real usage, add PDB"
git push

echo "==> Waiting for ArgoCD to detect and sync the change"
if command -v argocd >/dev/null 2>&1; then
  argocd app sync checkout-oom-demo
  argocd app wait checkout-oom-demo --health
else
  echo "argocd CLI not found locally - ArgoCD will pick up the change on its next poll,"
  echo "or sync manually from the UI."
fi
