# Postmortem: checkout-worker OOMKilled / CrashLoopBackOff

**Status:** Resolved
**Severity:** SEV-2 (modeled) - degraded checkout capacity, not a full outage
**Authors:** This demo repository

> This is a blameless postmortem for a **modeled/illustrative incident**
> reproduced by this repository, not a transcript of a real company's actual
> production outage. We could not verify a specific public postmortem that
> matches this exact story, so we built a runnable reproduction instead of
> attributing invented details to a real organization. The failure mode
> itself - missing/undersized memory requests and limits causing OOMKilled
> and CrashLoopBackOff on a critical workload - is extremely common and well
> documented (see the README's References section).

## Summary

The `checkout-worker` Deployment was rolled out with a memory limit of `20Mi`
and no memory request. Under normal simulated checkout traffic, the process's
real working set exceeded that limit within seconds, so the kernel/kubelet
OOMKilled the container (Exit Code 137) repeatedly, and Kubernetes cycled the
pods into `CrashLoopBackOff`. Checkout capacity was degraded for the duration
of the incident because a fraction of replicas were perpetually restarting
instead of serving traffic.

## Impact

- All 3 replicas of `checkout-worker` were affected; each cycled through
  `Running -> OOMKilled -> CrashLoopBackOff` roughly every 10-20 seconds.
- Readiness was never stable, so any upstream load balancer or Service would
  have seen intermittent `5xx`s / connection resets for checkout requests.
- No data was lost - the workload is stateless from Kubernetes' perspective -
  but sustained checkout latency/errors during the incident window would, in
  a real production system, directly reduce completed transactions.

## Timeline (modeled)

| Time (relative) | Event |
| --- | --- |
| T+0:00 | `manifests/live` (broken) synced by ArgoCD; `checkout-worker` pods start. |
| T+0:10 | First OOMKilled event as simulated order traffic grows the process's memory past 20Mi. |
| T+0:15 | Pods enter `CrashLoopBackOff`; restart counts climb. |
| T+2:00 | `k8sgpt analyze` run against the namespace; reports OOMKilled root cause and recommends raising `resources.requests/limits.memory`. |
| T+4:00 | `scripts/03-apply-fix-via-git.sh` copies corrected manifests into `manifests/live`, commits, and pushes. |
| T+4:30 | ArgoCD's automated+selfHeal sync applies the fix; pods roll out with `requests.memory: 160Mi` / `limits.memory: 256Mi`. |
| T+5:00 | Restart counts stop climbing; all pods reach `Running`/`Ready`; k8sgpt reports no issues. |

## Root cause

The `checkout-worker` Deployment's container spec set `resources.limits.memory`
far below the workload's real memory footprint, and did not set
`resources.requests.memory` at all. Kubernetes therefore scheduled the pod
without properly accounting for its real needs, and the kubelet enforced the
too-low limit by killing the process (OOMKilled) whenever the working set
grew past it.

## Contributing factors

- No automated policy (e.g. a `LimitRange`, admission policy, or CI check)
  existed in this namespace to reject Deployments missing resource
  requests/limits before they reached the cluster.
- The liveness probe's short `initialDelaySeconds`/low `failureThreshold` in
  the broken manifest meant the container was also at risk of being restarted
  for slow-start reasons on top of the OOM issue, making the signal noisier.
- There was no pre-existing dashboard/alert on container restart reason
  (`OOMKilled` specifically), so the only way to learn the root cause quickly
  was to run k8sgpt or read `kubectl describe pod` by hand.

## What went well

- GitOps meant the fix was a single, reviewable git commit rather than an
  imperative `kubectl edit` against the live cluster - the change is auditable
  and reproducible.
- k8sgpt's analysis pointed directly at the resource configuration as the
  cause, cutting down the time spent manually reading pod events.
- The corrected manifests bundle a PodDisruptionBudget, so future rollouts
  of this workload can't accidentally take down all replicas at once.

## What went wrong / could be improved

- Nothing in CI (`ci-build-push.yml`) currently rejects a Deployment manifest
  that omits `resources.requests`/`limits` - the YAML validation step only
  checks that the file parses, not that it's well-formed from a policy
  standpoint.
- There was no automatic rollback: recovery depended on someone noticing the
  incident and running the diagnose/fix workflow.

## Action items

| Action | Owner | Status |
| --- | --- | --- |
| Add a namespace-wide `LimitRange` with sane defaults (done in `manifests/reference-fixed/`, consider making this part of `manifests/live` permanently) | Platform | Done in this repo |
| Add a CI policy check (e.g. `conftest`/OPA or `kubeconform` with a custom schema) that fails the build if a container is missing `resources.requests`/`limits` | Platform | Proposed |
| Add a scheduled (cron) GitHub Actions run of `k8sgpt analyze` against the cluster so regressions are caught even without a manual trigger | Platform | Proposed |
| Add a basic alert on `OOMKilled` container restarts via your monitoring stack of choice | Platform | Proposed |

## Lessons learned

Resource requests and limits are not an optional tuning detail - they are
part of a workload's contract with the scheduler and the kubelet. Missing or
badly-sized values turn ordinary load growth into a hard failure (OOMKilled)
instead of a gradual, observable one. Pairing GitOps (so fixes are audited and
reproducible) with an AI-assisted diagnostic tool like k8sgpt (so the root
cause is surfaced quickly) meaningfully shortens the path from "something is
wrong" to "here is the exact YAML field to change."
