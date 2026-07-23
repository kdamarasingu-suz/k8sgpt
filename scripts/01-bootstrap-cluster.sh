#!/usr/bin/env bash
# One-time cluster bootstrap: installs ArgoCD and points it at this repo's
# manifests/live path. Run this once against any real Kubernetes cluster
# (kind, k3d, EKS/GKE/AKS, etc. - NOT minikube).
#
# After this runs, day-to-day changes are made by editing files under
# manifests/ and pushing to git - ArgoCD takes it from there. GitHub Actions
# (.github/workflows/) handles building the image and running k8sgpt on
# demand; it does not deploy anything directly.
set -euo pipefail

echo "==> Building the checkout-worker image locally"
docker build -t checkout-worker:latest app
if command -v kind >/dev/null 2>&1; then
  kind load docker-image checkout-worker:latest
elif command -v k3d >/dev/null 2>&1; then
  k3d image import checkout-worker:latest
fi

echo "==> Installing ArgoCD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "==> Waiting for ArgoCD server to be ready"
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s

echo "==> Applying the Application (points ArgoCD at manifests/live, currently the BROKEN version)"
kubectl apply -f argocd/application.yaml

cat <<'EOF'

ArgoCD is now watching manifests/live in this repo and will deploy the broken
checkout-worker Deployment (memory limit far too low, no request).

To view the ArgoCD UI locally:
  kubectl -n argocd port-forward svc/argocd-server 8080:443
  # username: admin
  # password: kubectl -n argocd get secret argocd-initial-admin-secret \
  #             -o jsonpath='{.data.password}' | base64 -d
EOF
