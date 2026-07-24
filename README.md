# k8sgpt

A from-scratch, runnable reproduction of one of the most common real-world
Kubernetes incidents - a critical workload getting **OOMKilled** and cycling
into **CrashLoopBackOff** because its `resources.requests`/`limits` are
missing or misconfigured - and its resolution using **GitHub Actions**,
**ArgoCD**, **Python**, **Kubernetes**, and **k8sgpt**.

## The problem

When a Deployment doesn't set memory `resources.requests`/`limits` (or sets
the limit far below what the workload actually needs), the scheduler
under-accounts for the pod's real footprint and the kubelet/kernel OOM killer
terminates the container (`OOMKilled`, Exit Code 137) once it exceeds that
limit. Kubernetes then restarts it, it OOMs again, and the pod settles into
`CrashLoopBackOff`. If that workload sits on a critical path - a payment or
checkout service, for example - this directly degrades or halts transactions
for as long as the misconfiguration exists.

## Real-world basis

This exact failure pattern (missing/undersized memory requests and limits
causing OOMKilled + CrashLoopBackOff) is one of the most frequently documented
Kubernetes anti-patterns. We looked for a specific, named, public postmortem
that matches this precise story and could not verify one, so this repository
does **not** claim to reproduce any single company's real incident. Instead,
it's a genuine, runnable reproduction of the well-documented pattern itself.
See References below for real sources describing this pattern.

## Architecture

```
Git (this repo) ---> GitHub Actions (CI) ---> GHCR (image registry)
      |
      +-----------> ArgoCD (CD/GitOps) ---> Kubernetes cluster
                                                    |
                                                    +--> k8sgpt (diagnosis)
```

- **GitHub Actions** (`.github/workflows/ci-build-push.yml`) builds the
  `checkout-worker` Python image and pushes it to GHCR, and lints the
  Kubernetes manifests, on every push to `app/`.
- **ArgoCD** (`argocd/application.yaml`) continuously syncs whatever is
  committed under `manifests/live` into the cluster, with automated+selfHeal
  sync - the fix is applied by committing corrected YAML to git, not by
  running `kubectl apply` by hand.
- **k8sgpt** diagnoses the running cluster, either locally or via the manual
  `.github/workflows/k8sgpt-diagnose.yml` workflow.
- **Python** (`app/checkout_worker.py`, standard library only) simulates a
  real checkout service whose memory usage legitimately grows under load.

## Repository layout

```
app/                        Python checkout-worker service + Dockerfile
manifests/live/              BROKEN manifests (what ArgoCD deploys initially)
manifests/reference-fixed/   FIXED manifests (correct requests/limits, PDB)
argocd/application.yaml      ArgoCD Application (GitOps CD)
.github/workflows/           GitHub Actions (CI + on-demand k8sgpt diagnosis)
scripts/                     Bootstrap and observe helper scripts
```

## Quick start

Requirements: a real Kubernetes cluster (`kind`, `k3d`, or a managed
cluster - **not minikube**), `kubectl`, `docker`, and optionally the `argocd`
and `k8sgpt` CLIs installed locally.

```bash
# 1. Bootstrap ArgoCD and deploy the BROKEN version
./scripts/01-bootstrap-cluster.sh

# 2. Watch the OOMKilled / CrashLoopBackOff incident happen
./scripts/02-observe-incident.sh

# 3. Diagnose with k8sgpt
k8sgpt analyze --explain --filter=Pod --namespace checkout-oom-demo

```

## Required repository secrets (for the GitHub Actions workflows)

- `KUBE_CONFIG` - base64-encoded kubeconfig for a real cluster, used only by
  the manual `k8sgpt-diagnose` workflow to run diagnostics.
- `OPENAI_API_KEY` (optional) - if you want k8sgpt's `--explain` output to use
  an AI backend in CI; without it, k8sgpt still reports raw findings.

`GITHUB_TOKEN` (used to push images to GHCR) is provided automatically by
GitHub Actions and does not need to be configured.

## References

- Kubernetes docs: [Resource Management for Pods and Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/)
- Kubernetes docs: [Configure Default Memory Requests and Limits for a Namespace](https://kubernetes.io/docs/tasks/administer-cluster/manage-resources/memory-default-namespace/)
- [k8sgpt](https://k8sgpt.ai) and the [k8sgpt-ai/k8sgpt](https://github.com/k8sgpt-ai/k8sgpt) GitHub repository
- [ArgoCD documentation](https://argo-cd.readthedocs.io/)
