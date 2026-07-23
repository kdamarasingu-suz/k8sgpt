# Incident walkthrough: OOMKilled checkout-worker

## Scope and honesty note

This repository models a well-documented, extremely common Kubernetes failure
pattern: a workload with no (or too-low) memory `resources.requests`/`limits`
gets OOMKilled and cycles into `CrashLoopBackOff`. This exact pattern, and the
business impact of it hitting a checkout/payment path, is described across
Kubernetes' own documentation and many public engineering write-ups (see the
References section in the main README). We are not claiming this reproduces a
specific, named company's real production postmortem - we could not verify
one publicly - so everything below is a real, runnable reproduction of the
failure mode rather than a re-telling of someone else's incident.

## Architecture

- **Git (this repo)** is the single source of truth for both application code
  and Kubernetes manifests.
- **GitHub Actions** (`.github/workflows/ci-build-push.yml`) is the CI half:
  it builds the `checkout-worker` Python image, pushes it to GHCR, and lints
  the YAML manifests on every push to `app/`.
- **ArgoCD** (`argocd/application.yaml`) is the CD/GitOps half: it continuously
  syncs whatever is committed under `manifests/live` into the
  `checkout-oom-demo` namespace on your cluster, with `selfHeal` enabled so
  manual `kubectl` drift gets reverted automatically.
- **k8sgpt** is the diagnosis tool, run either locally (`scripts/`) or via the
  `.github/workflows/k8sgpt-diagnose.yml` manual workflow against your
  cluster.

## Step 1 - Bootstrap

```bash
./scripts/01-bootstrap-cluster.sh
```

This builds the `checkout-worker` image, installs ArgoCD, and applies
`argocd/application.yaml`, which immediately starts syncing the **broken**
manifests in `manifests/live/deployment.yaml` (memory limit `20Mi`, no
request) into the cluster.

## Step 2 - Watch the incident happen

```bash
./scripts/02-observe-incident.sh
```

Within a few seconds of the first requests being processed, the
`checkout-worker` pods exceed the 20Mi memory ceiling. You'll see restart
counts climbing and `lastState.terminated.reason: OOMKilled` in the output,
and the Deployment settling into `CrashLoopBackOff`.

## Step 3 - Diagnose with k8sgpt

Locally:

```bash
k8sgpt analyze --explain --filter=Pod --namespace checkout-oom-demo
```

Or via GitHub Actions: run the **k8sgpt-diagnose** workflow from the Actions
tab (requires a `KUBE_CONFIG` repo secret pointing at your cluster).

Illustrative output (actual wording depends on your k8sgpt version/backend -
this is representative, not a captured transcript):

```text
0: Pod checkout-oom-demo/checkout-worker-7c9d4f8b6-x2q1p
- Error: Back-off restarting failed container checkout-worker in pod
  checkout-worker-7c9d4f8b6-x2q1p_checkout-oom-demo

Explanation: The container was terminated with reason OOMKilled (exit code
137), meaning it exceeded its memory limit of 20Mi. The Deployment does not
set a memory request, so the scheduler under-accounted for this pod's real
footprint. Increase resources.requests.memory and resources.limits.memory to
match the workload's actual usage, and consider adding a PodDisruptionBudget
so remediation doesn't cause a full outage while rolling out.
```

## Step 4 - Apply the fix via GitOps

```bash
./scripts/03-apply-fix-via-git.sh
```

This copies `manifests/reference-fixed/*.yaml` over `manifests/live/`,
commits, and pushes. ArgoCD's `selfHeal`+`automated` sync policy picks up the
change (or you can force it with `argocd app sync checkout-oom-demo`). The
fixed Deployment sets `resources.requests.memory: 160Mi` /
`limits.memory: 256Mi` (sized to the workload's real usage), adds a
readiness probe, relaxes the liveness probe thresholds, and a
PodDisruptionBudget keeps at least 2 replicas available during rollout.

## Step 5 - Confirm resolution

Re-run `scripts/02-observe-incident.sh` or `k8sgpt analyze` again - restart
counts stop climbing, pods reach `Running`/`Ready`, and k8sgpt reports no
issues for the namespace.
