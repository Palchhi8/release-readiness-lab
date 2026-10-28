# Configuration & Environment Verification: Checkout API (v2.4)

- **Service Name:** `checkout-api`
- **Candidate Version:** `v2.4`
- **Target Namespace:** `checkout-system`
- **Evaluator:** Release Engineering / SRE Team
- **Status:** **CRITICAL MISCONFIGURATION (BLOCKED)**

---

## 1. Executive Summary

A comprehensive audit of configuration artifacts was conducted across [docs/architecture.md](file:///c:/Users/jainp/OneDrive/Desktop/release-readiness-lab/docs/architecture.md), [app/app.py](file:///c:/Users/jainp/OneDrive/Desktop/release-readiness-lab/app/app.py), [k8s/configmap.yaml](file:///c:/Users/jainp/OneDrive/Desktop/release-readiness-lab/k8s/configmap.yaml), and [k8s/deployment.yaml](file:///c:/Users/jainp/OneDrive/Desktop/release-readiness-lab/k8s/deployment.yaml). 

The audit reveals a **catastrophic configuration gap**: the Kubernetes manifests completely omit the two critical backing service variables — `DATABASE_URL` and `REDIS_URL`. If deployed to production, the Checkout API will default to volatile in-memory SQLite and a local dictionary cache across **3 replicated pods**. This creates an immediate **data loss and split-brain disaster**.

---

## 2. Configuration & Environment Audit Matrix

| Configuration Variable | Required in `architecture.md` | Handled in `app.py` | Present in `configmap.yaml` | Present in `deployment.yaml` | Production Storage Medium | Operational Assessment |
| :--- | :---: | :---: | :---: | :---: | :---: | :--- |
| `PORT` | Yes (Default: 5000) | Yes (`os.getenv("PORT", 5000)`) | Yes (`PORT: "5000"`) | Indirect via `envFrom` | ConfigMap | **PASS** (Matches containerPort 5000) |
| `LOG_LEVEL` | Yes (Default: INFO) | Yes (`os.getenv("LOG_LEVEL", "INFO")`) | Yes (`LOG_LEVEL: "info"`) | Indirect via `envFrom` | ConfigMap | **PASS** (Properly set to info) |
| `DATABASE_URL` | **Yes (PostgreSQL)** | Fallback to SQLite | **MISSING** | **MISSING** | **Secret (K8s)** | **CRITICAL FAIL** (Causes silent fallback to ephemeral SQLite) |
| `REDIS_URL` | **Yes (Redis Cache)** | Fallback to dict | **MISSING** | **MISSING** | **Secret (K8s)** | **CRITICAL FAIL** (Causes silent fallback to local unshared memory) |

---

## 3. Detailed Root Cause & Impact Analysis

### 3.1 The Ephemeral In-Memory Fallback Trap
In `app/app.py`, lines 27-46 govern database and cache connectivity:
```python
db_url = os.getenv("DATABASE_URL")
redis_url = os.getenv("REDIS_URL")

if db_url:
    db_status = "connected"
else:
    db_status = "warning_fallback_sqlite"
    logger.warning("DATABASE_URL is not set! Using unstable, volatile in-memory SQLite fallback.")

if redis_url:
    redis_status = "connected"
else:
    redis_status = "warning_fallback_local"
    logger.warning("REDIS_URL is not set! Using volatile local in-memory dict cache fallback.")
```

Meanwhile, in `k8s/configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-api-config
  namespace: checkout-system
data:
  LOG_LEVEL: "info"
  PORT: "5000"
  # Note: Developers forgot to include DATABASE_URL and REDIS_URL here.
  # This causes the application to default to volatile, in-memory SQLite and local cache.
```

### 3.2 Multi-Pod Split-Brain & Data Loss Scenario
In `k8s/deployment.yaml`, line 11 specifies `replicas: 3`:
```yaml
spec:
  replicas: 3
```

When 3 pods start without `DATABASE_URL` and `REDIS_URL`:
1. **Pod Isolation (Split-Brain):** Pod 1, Pod 2, and Pod 3 each spawn their own private in-memory SQLite database and process-local cache.
2. **Transaction Inconsistency:** When a customer adds an item to cart or initiates a checkout on Pod 1, Pod 2 and Pod 3 know nothing about it. Round-robin load balancing via `checkout-api-service` will route the payment confirmation request to Pod 2, resulting in "Cart Not Found" or payment reconciliation failures.
3. **Catastrophic Data Loss:** Whenever a pod is restarted, scaled, or rescheduled, its memory is wiped. All orders processed in that pod's in-memory SQLite database are permanently lost.

```
       [Client Traffic]
              │
    [checkout-api-service]
       /      │       \
      ▼       ▼        ▼
   [Pod 1]  [Pod 2]  [Pod 3]
    (Mem)    (Mem)    (Mem)
   SQLite   SQLite   SQLite   <-- THREE SEPARATE DATABASES! NO SHARED STATE!
```

### 3.3 Plaintext Credential Security Vulnerability
The developer note in `configmap.yaml` suggests adding `DATABASE_URL` and `REDIS_URL` directly into the ConfigMap. 
**This violates fundamental security governance.**
- Database and cache connection URIs contain authentication credentials:
  `postgresql://<user>:<password>@<host>:<port>/<dbname>`
- ConfigMaps are stored in plaintext and often accessible by cluster developers and monitoring services without RBAC restriction.
- **Rule:** Credentials must be stored in Kubernetes `Secret` resources or retrieved from an external secrets manager (e.g., HashiCorp Vault, AWS Secrets Manager, or External Secrets Operator).

---

## 4. Remediation Plan & Target Configuration

To turn this candidate into an approvable state, the following manifests must be deployed:

### 4.1 Production Kubernetes Secret (`k8s/secret.yaml.example`)
Create a dedicated secret for sensitive connection strings:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: checkout-api-secrets
  namespace: checkout-system
type: Opaque
stringData:
  DATABASE_URL: "postgresql://checkout_app:P@ssw0rdProd2026@postgres.checkout-system.svc.cluster.local:5432/checkout_prod"
  REDIS_URL: "redis://:R3d1sS3cur3Auth@redis.checkout-system.svc.cluster.local:6379/0"
```

### 4.2 Hardened ConfigMap (`k8s/configmap.yaml`)
Retain only non-sensitive configuration settings:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: checkout-api-config
  namespace: checkout-system
data:
  LOG_LEVEL: "info"
  PORT: "5000"
  ENVIRONMENT: "production"
  GUNICORN_WORKERS: "4"
  GUNICORN_THREADS: "2"
```

### 4.3 Updated Deployment Spec (`k8s/deployment.yaml`)
Inject both ConfigMap and Secret into the container:
```yaml
        envFrom:
        - configMapRef:
            name: checkout-api-config
        - secretRef:
            name: checkout-api-secrets
```

---

## 5. Pre-Flight Verification Checklist

Before approving any deployment window for Checkout API v2.4, the SRE team must execute and verify the following commands against the target cluster:

- [ ] **Verify Namespace Exists:**
  ```bash
  kubectl get namespace checkout-system
  ```
- [ ] **Verify Secrets Injected:**
  ```bash
  kubectl get secret checkout-api-secrets -n checkout-system
  ```
- [ ] **Verify Backing Database Network Reachability:**
  ```bash
  kubectl run netcheck --rm -i --tty --image=busybox -n checkout-system -- nc -zv postgres.checkout-system.svc.cluster.local 5432
  ```
- [ ] **Verify Backing Cache Network Reachability:**
  ```bash
  kubectl run netcheck --rm -i --tty --image=busybox -n checkout-system -- nc -zv redis.checkout-system.svc.cluster.local 6379
  ```
- [ ] **Verify Pod Environment Injection:**
  ```bash
  kubectl exec -it <pod-name> -n checkout-system -- printenv | grep -E 'DATABASE_URL|REDIS_URL|LOG_LEVEL'
  ```
- [ ] **Verify Health Endpoint Reports Connected:**
  ```bash
  kubectl exec -it <pod-name> -n checkout-system -- curl -s http://localhost:5000/health | grep '"database":"connected"'
  ```

---

## 6. Audit Verdict

**Result: REJECTED (NO-GO)**
The deployment candidate is not release-ready due to unconfigured database and cache dependencies that trigger catastrophic multi-pod data loss.
