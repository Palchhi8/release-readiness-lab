# Rollback Plan: Checkout API (v2.4 -> v2.3)

- **Service Name:** `checkout-api`
- **Candidate Version:** `v2.4`
- **Target Rollback Version:** `v2.3` (Last Known-Good Stable Production Release)
- **Target Namespace:** `checkout-system`
- **Maximum Tolerable Downtime (MTD):** 5 Minutes
- **Target Recovery Time Objective (RTO / MTTR):** < 3 Minutes
- **Status:** **APPROVED FOR EMERGENCY USE**

---

## 1. Baseline Identification: Known-Good Stable Version

According to [docs/architecture.md](file:///c:/Users/jainp/OneDrive/Desktop/release-readiness-lab/docs/architecture.md), the release history is documented as follows:

| Version | Release Date | Author | Deployment Status | Notes |
| :--- | :--- | :--- | :--- | :--- |
| `v2.0` | 2026-04-10 | Dev Team | Deployed (Prod) | Initial Flask conversion |
| `v2.1` | 2026-05-02 | Dev Team | Deployed (Prod) | Add health checks, fix cache bugs |
| `v2.2` | 2026-05-20 | Dev Team | Deployed (Prod) | Optimize database pool sizes |
| **`v2.3`** | **2026-06-01** | **Dev Team** | **Deployed (Prod - STABLE)** | **Current verified production baseline** |
| `v2.4` | 2026-06-17 | Dev Team | Release Candidate | Minor performance improvements for checkouts |

**Target Rollback Image:** `kalvium/checkout-api:v2.3`  
**Target Manifest Version:** Deployment with `version: v2.3` label and image tag `v2.3`.

---

## 2. Automated & Manual Rollback Triggers

A rollback must be initiated immediately upon encountering any of the following operational breaches during or within 60 minutes of deployment:

| Trigger ID | Failure Metric | Threshold | Detection Method |
| :--- | :--- | :--- | :--- |
| **TR-01** | **HTTP 5xx Error Rate** | > 1.0% of total checkout traffic over 2 consecutive minutes | Prometheus alert `High5xxRate` / Datadog APM |
| **TR-02** | **Degraded Health Check** | `/health` returning `warning_fallback_sqlite` or non-200 | Synthetic probe / K8s readiness probe failures |
| **TR-03** | **Pod CrashLoopBackOff** | Any replica restarting > 3 times in 5 minutes | `kubectl get pods -n checkout-system` |
| **TR-04** | **Latency Degradation (P95)** | P95 response latency > 800ms for 3 minutes | Ingress latency metric `nginx_ingress_controller_request_duration_seconds` |
| **TR-05** | **Order Processing Failure** | Failed payment/order conversions > 2% increase | Business telemetry dashboard |
| **TR-06** | **Rollout Timeout** | Deployment rollout not progressing within 5 minutes | Kubernetes deployment progress deadline |

---

## 3. Step-by-Step Rollback Execution Procedures

### Preparation: Establish Authority & Incident Bridge
1. The **On-Call SRE** or **Release Owner** declares: `"INITIATING ROLLBACK TO v2.3"`.
2. Post announcement to Slack `#release-war-room` and open the voice bridge.

---

### Procedure A: Fast Rollback via Kubernetes History (Recommended)

When rolling back immediately following an automated or interactive deployment:

#### Step 1: Check Deployment Revision History
```bash
kubectl rollout history deployment/checkout-api -n checkout-system
```

#### Step 2: Roll Back to Previous Revision
```bash
kubectl rollout undo deployment/checkout-api -n checkout-system
```
*Expected Output:*
```text
deployment.apps/checkout-api rolled back
```

#### Step 3: Monitor Rollout Progress
```bash
kubectl rollout status deployment/checkout-api -n checkout-system --timeout=120s
```
*Expected Output:*
```text
Waiting for deployment "checkout-api" rollout to finish: 1 of 3 updated replicas are available...
Waiting for deployment "checkout-api" rollout to finish: 2 of 3 updated replicas are available...
deployment "checkout-api" successfully rolled out
```

---

### Procedure B: Deterministic Image Rollback (Direct Container Tag)

If deployment history is ambiguous, reset directly to the known-good container image `v2.3`:

#### Step 1: Force Container Image Update to v2.3
```bash
kubectl set image deployment/checkout-api checkout-api=kalvium/checkout-api:v2.3 -n checkout-system --record
```

#### Step 2: Patch Metadata Labels
```bash
kubectl patch deployment checkout-api -n checkout-system --type='json' -p='[
  {"op": "replace", "path": "/metadata/labels/version", "value": "v2.3"},
  {"op": "replace", "path": "/spec/template/metadata/labels/version", "value": "v2.3"}
]'
```

#### Step 3: Verify Rollout Completion
```bash
kubectl rollout status deployment/checkout-api -n checkout-system
```

---

### Procedure C: Standalone Rollback Script

An automated, non-interactive script has been authored at [scripts/rollback.sh](file:///c:/Users/jainp/OneDrive/Desktop/release-readiness-lab/scripts/rollback.sh).

```bash
chmod +x scripts/rollback.sh
./scripts/rollback.sh
```

---

## 4. Post-Rollback Verification & Smoke Testing

Immediately after the rollback completes, execute the following verification steps:

### 4.1 Pod & Replica Verification
```bash
kubectl get pods -n checkout-system -l app=checkout-api
```
*Verification criteria:* All 3 replicas must show `STATUS: Running` and `READY: 1/1`.

### 4.2 Endpoint Version Validation
Query the service cluster IP or port-forward:
```bash
kubectl run verify-curl --rm -i --tty --image=curlimages/curl -n checkout-system -- curl -s http://checkout-api-service/
```
*Expected Response:*
```json
{
  "service": "checkout-api",
  "version": "v2.3",
  "message": "Release Readiness Demo"
}
```
**Assertion:** `"version"` must strictly equal `"v2.3"`.

### 4.3 Health Check Verification
```bash
kubectl run verify-curl --rm -i --tty --image=curlimages/curl -n checkout-system -- curl -s http://checkout-api-service/health
```
*Expected Response:*
```json
{
  "status": "healthy",
  "version": "v2.3",
  "checks": {
    "database": "connected",
    "redis": "connected"
  }
}
```
**Assertion:** `database` and `redis` must both report `"connected"`. No fallback warnings permitted.

### 4.4 Container Log Inspection
```bash
kubectl logs -l app=checkout-api -n checkout-system --tail=50
```
*Verification criteria:* No unhandled exceptions, zero traceback errors, log level corresponds to configured `LOG_LEVEL`.

---

## 5. State, Database, and Cache Considerations

1. **Database Schema Compatibility:**
   - Candidate `v2.4` contained code-level checkout performance optimizations and **did not execute database schema migrations**.
   - Rolling back code from `v2.4` to `v2.3` requires **no database downgrade scripts or data restoration**. The PostgreSQL database schema remains 100% compatible with `v2.3`.
2. **Redis Cache Invalidation:**
   - If `v2.4` modified serialization format or cached keys during its execution, purge stale cache keys:
   ```bash
   kubectl run redis-flush --rm -i --tty --image=redis:7-alpine -n checkout-system -- redis-cli -h redis.checkout-system.svc.cluster.local -a "$REDIS_AUTH" FLUSHDB ASYNC
   ```

---

## 6. Incident Reporting & Post-Mortem Requirement

Once the rollback is verified and traffic stabilizes:
1. Announce recovery on `#incidents` and update external status page.
2. Freeze all deployment pipelines for `checkout-api`.
3. Schedule an SRE Post-Mortem meeting within 24 hours to analyze root cause.
