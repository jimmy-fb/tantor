# VAPT Scanner

Automated **Vulnerability Assessment and Penetration Testing** (VAPT) tool for web applications and APIs. Wraps [OWASP ZAP](https://www.zaproxy.org/) (Zed Attack Proxy) in a simple one-command script that runs via Docker — no installation required beyond Docker itself.

---

## Tool Used

| Component | Details |
|-----------|---------|
| **Scanner** | [OWASP ZAP](https://www.zaproxy.org/) (Zed Attack Proxy) v2.17+ |
| **Docker Image** | [`zaproxy/zap-stable`](https://hub.docker.com/r/zaproxy/zap-stable) |
| **License** | Apache License 2.0 |

**OWASP ZAP** is the world's most widely used open-source web application security scanner, maintained by the [Open Worldwide Application Security Project (OWASP)](https://owasp.org/). It is designed to find security vulnerabilities in web applications during development and testing.

---

## Prerequisites

- **Docker** installed and running — [Get Docker](https://docs.docker.com/get-docker/)
- Target application must be accessible from your machine

That's it. The script automatically pulls the ZAP Docker image on first run.

---

## Quick Start

```bash
# Clone this repo
git clone https://github.com/<your-org>/vapt-scan.git
cd vapt-scan

# Make executable
chmod +x run-vapt.sh

# Run against any website
./run-vapt.sh https://your-app.example.com

# Run against an API with OpenAPI/Swagger spec
./run-vapt.sh https://api.example.com --api https://api.example.com/openapi.json
```

---

## Usage

```
./run-vapt.sh <target-url> [options]
```

### Options

| Flag | Description |
|------|-------------|
| `--api <url>` | URL to OpenAPI/Swagger spec — enables active API scan |
| `--full` | Run full active scan (slower, more thorough) |
| `--ajax` | Enable AJAX spider for JavaScript-heavy SPAs |
| `--auth <token>` | Bearer token for authenticated endpoint scanning |
| `--output <dir>` | Custom output directory (default: `./reports/<timestamp>/`) |
| `--minutes <n>` | Max scan duration in minutes (default: 10) |
| `--help` | Show help message |

---

## Examples

### Basic website scan
```bash
./run-vapt.sh https://myapp.example.com
```

### REST API with OpenAPI spec
```bash
./run-vapt.sh https://api.example.com \
  --api https://api.example.com/openapi.json
```

### Full active scan (deeper testing)
```bash
./run-vapt.sh https://myapp.example.com --full
```

### Authenticated scan with Bearer token
```bash
./run-vapt.sh https://staging.myapp.com \
  --api https://staging.myapp.com/openapi.json \
  --auth "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
```

### JavaScript SPA with AJAX spider
```bash
./run-vapt.sh https://myapp.com --ajax
```

### Local development server
```bash
./run-vapt.sh http://localhost:3000
./run-vapt.sh http://localhost:8000 --api http://localhost:8000/openapi.json
```

> **Note:** When scanning `localhost` or `127.0.0.1`, the script automatically converts the URL to `host.docker.internal` so the Docker container can reach your host machine. This works on macOS and Windows. On Linux, you may need to add `--network host` manually.

---

## Scan Types

### 1. Baseline Scan (Default)
Runs **passive analysis** — spiders the target and checks responses for security issues without sending attack payloads. Fast and safe for production.

**Checks include:** Missing security headers, cookie issues, information disclosure, insecure configurations, outdated libraries, etc.

### 2. API Scan (`--api`)
Imports the **OpenAPI/Swagger specification** and actively tests every documented endpoint with attack payloads. This is the most thorough scan for REST APIs.

**Checks include:** SQL injection, XSS, command injection, path traversal, XXE, SSTI, CSRF, authentication bypass, and 100+ more vulnerability types.

### 3. Full Active Scan (`--full`)
Crawls the entire application and runs active attack payloads against all discovered endpoints. This is the most thorough but slowest scan.

**Checks include:** Everything in baseline + API scan, plus deep crawling, form submission testing, and fuzzing.

---

## What It Tests

The scanner checks for **117+ vulnerability categories** across these areas:

| Category | Examples |
|----------|----------|
| **Injection** | SQL Injection (MySQL, PostgreSQL, Oracle, MsSQL), XPath, XSLT, SSTI, OS Command, CRLF, SSI |
| **Cross-Site Scripting** | Reflected XSS, Persistent XSS, DOM-Based XSS |
| **Remote Code Execution** | Log4Shell (CVE-2021-44228), Spring4Shell (CVE-2022-22965), React2Shell |
| **File Exploits** | Path Traversal, Remote File Inclusion, Hidden Files, .env/.htaccess leaks |
| **XML/SOAP** | XXE, Billion Laughs, SOAP Spoofing, SOAP XML Injection |
| **Auth & Session** | CSRF tokens, Weak Auth, Session Fixation, Cookie Scoping |
| **Information Disclosure** | PII, Source Code, Private IP, Error Messages, Spring Actuator |
| **Infrastructure** | Heartbleed, Cloud Metadata, Buffer Overflow, Format String |
| **Supply Chain** | Polyfill.io Malicious Domain, External Redirects |
| **Security Headers** | X-Content-Type-Options, CORS Policy, CSP, HSTS |

---

## Output

Reports are saved to `./reports/<timestamp>/` by default:

```
reports/
  20260309_134500/
    baseline-report.html    # Baseline scan HTML report
    baseline-report.json    # Baseline scan JSON data
    api-scan-report.html    # API scan HTML report (if --api used)
    api-scan-report.json    # API scan JSON data (if --api used)
    full-scan-report.html   # Full scan HTML report (if --full used)
    full-scan-report.json   # Full scan JSON data (if --full used)
    summary.json            # Overall scan summary
```

### Terminal Output

The script prints a color-coded summary on completion:

```
╔══════════════════════════════════════════════════════╗
║                  SCAN COMPLETE                      ║
╚══════════════════════════════════════════════════════╝

  Security Grade: A

  ✓ Passed:   249
  ⚠ Warnings: 4
  ✗ Failures: 0
```

### Grading

| Grade | Criteria |
|-------|----------|
| **A** | 0 failures, 0–2 warnings |
| **B** | 0 failures, 3–5 warnings |
| **C** | 0 failures, 6+ warnings |
| **F** | Any failures detected |

---

## CI/CD Integration

### GitHub Actions

```yaml
name: VAPT Scan
on:
  schedule:
    - cron: '0 2 * * 1'  # Weekly Monday 2am
  workflow_dispatch:

jobs:
  vapt:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run VAPT Scan
        run: |
          chmod +x run-vapt.sh
          ./run-vapt.sh ${{ vars.TARGET_URL }} \
            --api ${{ vars.API_SPEC_URL }} \
            --output ./vapt-results

      - name: Upload Reports
        uses: actions/upload-artifact@v4
        with:
          name: vapt-report-${{ github.run_number }}
          path: ./vapt-results/

      - name: Check for Failures
        run: |
          FAIL=$(cat ./vapt-results/summary.json | jq '.total_fail')
          if [ "$FAIL" -gt 0 ]; then
            echo "::error::VAPT scan found $FAIL failure(s)"
            exit 1
          fi
```

### GitLab CI

```yaml
vapt_scan:
  stage: test
  image: docker:latest
  services:
    - docker:dind
  script:
    - chmod +x run-vapt.sh
    - ./run-vapt.sh $TARGET_URL --api $API_SPEC_URL --output ./vapt-results
  artifacts:
    paths:
      - vapt-results/
    expire_in: 30 days
  only:
    - schedules
```

---

## Sample Report

A sample consolidated report is included in this repository:

- [`sample-reports/consolidated-vapt-report.html`](sample-reports/consolidated-vapt-report.html) — Visual HTML report from scanning a FastAPI + React application

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `Cannot reach target` | Ensure the target URL is accessible. For local servers, make sure they're running. |
| Docker permission denied | Run with `sudo` or add your user to the `docker` group. |
| Scans timeout | Increase duration with `--minutes 30` |
| Localhost not reachable from Docker | On Linux, use `--network host`. The script handles macOS/Windows automatically. |
| 403/401 responses | Use `--auth` to provide a Bearer token for authenticated endpoints. |

---

## License

MIT License. See [LICENSE](LICENSE) for details.

OWASP ZAP is licensed under the [Apache License 2.0](https://github.com/zaproxy/zaproxy/blob/main/LICENSE).
