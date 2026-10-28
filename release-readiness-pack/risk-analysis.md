# Operational Risk Analysis & Mitigation Matrix: Checkout API (v2.4)

- **Service Name:** `checkout-api`
- **Candidate Version:** `v2.4`
- **Evaluation Framework:** Standard SRE Failure Mode and Effects Analysis (FMEA)
- **Evaluator:** Release Engineering & Security SRE
- **Overall Risk Profile:** **UNACCEPTABLE (HIGH RISK)**

---

## 1. Executive Summary

This risk analysis evaluates the operational vulnerabilities, data integrity threats, and security exposures associated with shipping **Checkout API v2.4** in its current configuration. 

A total of **7 critical operational risks** have been identified, categorized, and scored. Three risks carry a **CRITICAL or HIGH severity with HIGH likelihood**, any single one of which warrants a complete deployment halt. Without immediate mitigation, approving this candidate would result in silent customer order loss, split-brain state corruption across pods, and security compliance failure.

---

## 2. Risk Evaluation Matrix

| Risk ID | Failure Mode / Threat | Severity | Likelihood | Impact Area | Mitigation Strategy | Assigned Owner | Post-Mitigation Residual Risk |
| :---: | :--- | :---: | :---: | :--- | :--- | :--- | :---: |
| **RSK-01** | **Missing `DATABASE_URL` in Manifests**<br>Causes silent fallback to volatile in-memory SQLite. | **CRITICAL** | **HIGH** | Data Integrity & Business Continuity | 1. Create K8s `Secret` containing valid PostgreSQL connection string.<br>2. Update `deployment.yaml` to inject secret via `envFrom`.<br>3. Remove in-memory fallback in code; fail fast on start if missing. | Data Architecture Lead | **LOW** |
| **RSK-02** | **Missing `REDIS_URL` in Manifests**<br>Causes local in-memory dict cache fallback across 3 pods. | **HIGH** | **HIGH** | State Consistency & Session Drift | 1. Deploy Redis instance and secret.<br>2. Inject `REDIS_URL` into pod environment.<br>3. Enforce distributed cache connectivity before serving requests. | Backend Engineering Lead | **LOW** |
| **RSK-03** | **Deceptive Health Checks (False 200 OK)**<br>`/health` returns HTTP 200 even when running on volatile fallbacks. K8s probes pass, routing customer traffic to degraded pods. | **HIGH** | **HIGH** | Traffic Routing & Observability | Refactor `/health` in `app/app.py` to return `HTTP 503 Service Unavailable` if database or cache is in `warning_fallback_*`. Prevent K8s traffic routing to unhealthy pods. | Site Reliability Engineer (SRE) | **LOW** |
| **RSK-04** | **Container Root Execution Privilege**<br>Dockerfile lacks non-root `USER` directive. Application runs as UID 0 (root). | **MEDIUM** | **MEDIUM** | Infrastructure Security | Modify `Dockerfile` to create non-root system group and user (`appuser` UID 10001) and switch user context before running Gunicorn. | DevSecOps Lead | **LOW** |
| **RSK-05** | **Vulnerable & Unpinned Dependencies**<br>`pip-audit` detected 12 CVEs (`Flask 3.0.2`, `pytest 8.0.2`). `pytest` bundled in production image. Transitive packages unpinned. | **HIGH** | **MEDIUM** | Supply Chain Security | 1. Upgrade Flask to `>= 3.1.3`.<br>2. Remove `pytest` from prod `requirements.txt`.<br>3. Generate pinned, hashed lockfile (`requirements.lock`). | Release Engineer | **LOW** |
| **RSK-06** | **Plaintext Credential Exposure**<br>ConfigMap documentation hints at adding database/cache credentials to `configmap.yaml`. | **HIGH** | **MEDIUM** | Secrets Governance & Compliance | Enforce policy prohibiting passwords in ConfigMaps. Use Kubernetes Secrets or External Secrets Operator with RBAC restrictions. | Security Architect | **LOW** |
| **RSK-07** | **Blind Deployment Script Execution**<br>`scripts/deploy.sh` executes `kubectl apply` and exits immediately without waiting for rollout status or verifying endpoint health. | **MEDIUM** | **HIGH** | Deployment Safety & MTTR | Update `scripts/deploy.sh` to include `kubectl rollout status` with timeout and automated curl smoke tests. | Automation / DevOps Engineer | **LOW** |

---

## 3. Deep Dive: Top Critical Operational Threats

### 3.1 RSK-01 & RSK-02: The Multi-Pod Split-Brain Hazard
In `k8s/deployment.yaml`, 3 pod replicas are declared. In `app/app.py`:
```python
if db_url:
    db_status = "connected"
else:
    db_status = "warning_fallback_sqlite"
    logger.warning("DATABASE_URL is not set! Using unstable, volatile in-memory SQLite fallback.")
```
- **The Threat:** When 3 pods start without `DATABASE_URL`, three separate in-memory SQLite instances are created in volatile RAM.
- **The Customer Experience Disaster:**
  1. Customer adds items to cart on Pod 1.
  2. Next checkout step is routed by Kubernetes Service to Pod 2.
  3. Pod 2 has an empty SQLite database; cart disappears or customer gets an unexpected 404 error.
  4. If a pod crashes or restarts under memory limit, all order history on that pod evaporates completely.
- **Severity Rating: CRITICAL.** Any deployment with this flaw directly violates data durability SLAs.

### 3.2 RSK-03: Probe Masking & False Readiness
Kubernetes relies on readiness probes to decide whether a pod should receive traffic:
```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 5000
  initialDelaySeconds: 5
  periodSeconds: 10
```
- **The Threat:** Because `/health` returns `HTTP 200` regardless of fallback state, the kubelet marks all 3 pods as `Ready (1/1)`.
- **Consequence:** Kubernetes endpoints controller adds all pods to `checkout-api-service`, exposing users to degraded in-memory instances while monitoring dashboards show green "100% healthy" status.
- **Severity Rating: HIGH.** This creates a severe observability blind spot.

### 3.3 RSK-05: Supply Chain & CVE Vulnerabilities
A live audit using `pip-audit 2.10.1` identified:
- `Flask 3.0.2`: Vulnerability `PYSEC-2026-2151`.
- `pytest 8.0.2`: Vulnerability `PYSEC-2026-1845`.
- **The Threat:** Leaving unpatched framework vulnerabilities in production introduces remote exploitation vectors. Furthermore, having `pytest` in production allows arbitrary test invocation tools inside the production container.
- **Severity Rating: HIGH.**

---

## 4. Risk Scoring & Residual Risk Assessment

### Risk Scoring Framework:
- **Severity Score:** Critical (5), High (4), Medium (3), Low (2), Negligible (1)
- **Likelihood Score:** Almost Certain (5), High (4), Medium (3), Low (2), Rare (1)
- **Risk Rating = Severity × Likelihood** (Threshold for Go: All risks must score < 9)

```
Risk Heatmap (Pre-Mitigation):
   5 (Crit) │                     [RSK-01]
   4 (High) │              [RSK-05,06] [RSK-02,03]
   3 (Med)  │              [RSK-04]   [RSK-07]
   2 (Low)  │
   1 (Neg)  │
            └─────────────────────────────────────
                 1 (Rare)   2 (Low)   3 (Med)   4 (High)   5 (Certain)
                                 Likelihood
```

| Risk ID | Pre-Mitigation Score (Severity × Likelihood) | Risk Level | Post-Mitigation Score | Target State |
| :---: | :---: | :---: | :---: | :---: |
| **RSK-01** | 5 × 4 = **20** | **CRITICAL** | 5 × 1 = **5** | Low |
| **RSK-02** | 4 × 4 = **16** | **HIGH** | 4 × 1 = **4** | Low |
| **RSK-03** | 4 × 4 = **16** | **HIGH** | 4 × 1 = **4** | Low |
| **RSK-04** | 3 × 3 = **9** | **MEDIUM** | 3 × 1 = **3** | Low |
| **RSK-05** | 4 × 3 = **12** | **HIGH** | 4 × 1 = **4** | Low |
| **RSK-06** | 4 × 3 = **12** | **HIGH** | 4 × 1 = **4** | Low |
| **RSK-07** | 3 × 4 = **12** | **MEDIUM** | 3 × 1 = **3** | Low |

---

## 5. Governance Decision

Under standard Release Governance rules, **no release may proceed to production with any open risk scoring >= 12 or any single CRITICAL severity risk**. 

Because `RSK-01`, `RSK-02`, and `RSK-03` remain completely unmitigated in the v2.4 deployment candidate, the candidate fails all release criteria.
