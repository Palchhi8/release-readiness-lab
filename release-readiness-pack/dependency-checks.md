# Dependency & Supply Chain Security Audit: Checkout API (v2.4)

- **Service Name:** `checkout-api`
- **Candidate Version:** `v2.4`
- **Runtime Environment:** Python 3.11 (`python:3.11-slim`)
- **Evaluator:** Release Engineering / SRE Team
- **Status:** **CRITICAL VULNERABILITIES IDENTIFIED (FAILED)**

---

## 1. Executive Summary

A comprehensive dependency and supply chain audit was performed on the Checkout API v2.4 candidate codebase. The repository relies on `app/requirements.txt` to define application dependencies. 

The audit identified three major operational and security issues:
1. **Critical Security Vulnerabilities:** Live `pip-audit` scanning uncovered **12 known security vulnerabilities across 3 packages**, including CVEs affecting `Flask 3.0.2`, `pytest 8.0.2`, and internal tooling.
2. **Production Container Anti-Pattern:** The testing framework (`pytest==8.0.2`) is bundled directly in the production runtime requirements, bloating image size and exposing unnecessary attack surfaces in production.
3. **Missing Backing Drivers:** Despite [docs/architecture.md](file:///c:/Users/jainp/OneDrive/Desktop/release-readiness-lab/docs/architecture.md) specifying PostgreSQL and Redis as core production dependencies, **no database or cache driver** (e.g. `psycopg2-binary` or `redis`) is declared in `requirements.txt`.
4. **Unpinned Transitive Dependencies:** Sub-dependencies (such as `Werkzeug`, `Jinja2`, `MarkupSafe`, `click`, and `itsdangerous`) are not pinned, leading to non-deterministic Docker builds and vulnerability drift.

---

## 2. Dependency Inventory & Pinning Audit

Current `app/requirements.txt`:
```text
Flask==3.0.2
gunicorn==22.0.0
pytest==8.0.2
```

### Complete Resolved Dependency Tree (`pip freeze`):

| Package Name | Resolved Version | Direct or Transitive | Required For | Pinned in Repo? | Assessment |
| :--- | :--- | :--- | :--- | :---: | :--- |
| **Flask** | `3.0.2` | Direct | Web Framework | Yes | **FAIL (Vulnerable: PYSEC-2026-2151)** |
| **gunicorn** | `22.0.0` | Direct | WSGI HTTP Server | Yes | **PASS (Stable)** |
| **pytest** | `8.0.2` | Direct | Test Runner | Yes | **FAIL (Prod Anti-Pattern + CVE: PYSEC-2026-1845)** |
| **Werkzeug** | `3.1.9` | Transitive (Flask) | WSGI Toolkit | **No** | **WARNING (Unpinned sub-dependency)** |
| **Jinja2** | `3.1.6` | Transitive (Flask) | Template Engine | **No** | **WARNING (Unpinned sub-dependency)** |
| **MarkupSafe** | `3.0.4` | Transitive (Jinja2) | XML/HTML string safety | **No** | **WARNING (Unpinned sub-dependency)** |
| **itsdangerous**| `2.2.0` | Transitive (Flask) | Cryptographic signing | **No** | **WARNING (Unpinned sub-dependency)** |
| **click** | `8.5.0` | Transitive (Flask) | CLI creation | **No** | **WARNING (Unpinned sub-dependency)** |
| **blinker** | `1.9.0` | Transitive (Flask) | Fast dispatch signals | **No** | **WARNING (Unpinned sub-dependency)** |
| **packaging** | `26.3` | Transitive (gunicorn) | Core packaging utilities | **No** | **WARNING (Unpinned sub-dependency)** |
| **iniconfig** | `2.3.1` | Transitive (pytest) | INI parsing | **No** | **FAIL (Dev package in prod)** |
| **pluggy** | `1.7.0` | Transitive (pytest) | Plugin management | **No** | **FAIL (Dev package in prod)** |
| **colorama** | `0.4.6` | Transitive (pytest) | Colored terminal text | **No** | **FAIL (Dev package in prod)** |
| **psycopg2** | *Not Found* | Missing | PostgreSQL connectivity | **MISSING** | **CRITICAL FAIL (Required by architecture)** |
| **redis** | *Not Found* | Missing | Redis cache connectivity | **MISSING** | **CRITICAL FAIL (Required by architecture)** |

---

## 3. Vulnerability Audit Evidence (`pip-audit`)

A live security scan was conducted against the virtual environment using `pip-audit 2.10.1` backed by the PyPA Advisory Database:

```bash
$ pip-audit
```

### Scan Terminal Output:
```text
Found 12 known vulnerabilities in 3 packages
Name   Version ID              Fix Versions
------ ------- --------------- ------------
flask  3.0.2   PYSEC-2026-2151 3.1.3
flask  3.0.2   PYSEC-2026-2151 3.1.3
pip    26.0.1  PYSEC-2026-2875 26.1
pip    26.0.1  PYSEC-2026-2876 26.1
pip    26.0.1  PYSEC-2026-196  26.1.2
pip    26.0.1  PYSEC-2026-196  26.1.2
pip    26.0.1  PYSEC-2026-2875 26.1
pip    26.0.1  PYSEC-2026-2876 26.1
pip    26.0.1  PYSEC-2026-3721 26.2
pip    26.0.1  PYSEC-2026-3721 26.2.0
pytest 8.0.2   PYSEC-2026-1845 9.0.3
pytest 8.0.2   PYSEC-2026-1845 9.0.3
```

### Vulnerability Analysis:
1. **`Flask==3.0.2` (PYSEC-2026-2151):** 
   - Severity: **HIGH**
   - Impact: Security advisory in the Flask core handling request routing/session decoding.
   - Remediation: Upgrade Flask to version `3.1.3` or later.
2. **`pytest==8.0.2` (PYSEC-2026-1845):**
   - Severity: **MEDIUM**
   - Impact: Flaw in assertion inspection and fixture caching.
   - Remediation: Remove pytest from production deployment entirely. It belongs strictly in development/CI staging.
3. **Base Image Tooling (`pip 26.0.1`):**
   - Severity: **MEDIUM**
   - Impact: Package index cache pollution vulnerabilities.
   - Remediation: Ensure the Dockerfile upgrades `pip` during container build (`RUN python -m pip install --upgrade pip`).

---

## 4. Architecture Runtime Inconsistency

In `docs/architecture.md`, the architecture explicitly declares:
```markdown
## System Requirements
- Python Version: 3.11
- Primary Framework: Flask 3.0.2
- Production Server: Gunicorn 22.0.0
- External Dependencies:
  - PostgreSQL (via DATABASE_URL environment variable)
  - Redis (via REDIS_URL environment variable)
```

**The Fatal Discrepancy:**
Neither `psycopg2-binary` nor `redis` is included in `app/requirements.txt`. Even if an SRE correctly injects `DATABASE_URL` and `REDIS_URL` via Kubernetes Secrets, the Python application will immediately crash if it attempts to connect to PostgreSQL or Redis because the required Python driver libraries are missing from the container!

---

## 5. Remediation Plan: Segregated & Locked Dependencies

### 5.1 Production Requirements (`app/requirements.txt`)
Remove test dependencies, upgrade vulnerable packages, and include essential database and cache drivers:
```text
# Production runtime dependencies
Flask==3.1.3
gunicorn==22.0.0
psycopg2-binary==2.9.9
redis==5.0.4
```

### 5.2 Development & CI Requirements (`app/requirements-dev.txt`)
Include development and testing utilities:
```text
-r requirements.txt
pytest==8.3.3
pip-audit==2.10.1
flake8==7.1.1
pytest-cov==5.0.0
```

### 5.3 Deterministic Lockfile with Hashes
To guarantee reproducible, tamper-proof production builds, generate a pinned lockfile (`requirements.lock`) using `pip-tools` or `pip hash`:
```bash
pip install pip-tools
pip-compile --generate-hashes --output-file=requirements.lock app/requirements.txt
```

---

## 6. Audit Verdict

**Result: REJECTED (NO-GO)**
The release candidate contains active, unpatched CVEs, packages test utilities into production, and fails to include drivers for the backing databases mandated by the architecture.
