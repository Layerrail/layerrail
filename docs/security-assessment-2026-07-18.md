# LayerRail Console Security Assessment

**Assessment date:** 2026-07-18

**Production target:** `https://console.layerrail.com`

**Application:** LayerRail Ruby/Roda control plane

**Assessment type:** Authorized, non-destructive production assessment plus isolated local code and runtime testing

## Executive summary

The assessment found one high-risk application issue: authenticated project members with billing permissions could cause LayerRail servers to request attacker-selected private, loopback, link-local, or cloud-metadata addresses through Edge origins, uptime checks, and monitoring webhooks. The same URL could also resolve differently between validation and connection time. This issue has been remediated with public-address validation on every request and DNS-pinned connections.

The assessment also identified vulnerable runtime dependencies, unbounded response buffering in outbound HTTP paths, proxy-header trust issues, overly broad public-page CSP allowances, inconsistent security headers on static and redirect responses, and potentially sensitive Resend error logging. These issues have been remediated and covered by regression tests.

No authentication bypass, project authorization bypass, permissive CORS policy, unsigned webhook path, SQL injection, exposed live credential, production TLS downgrade, or destructive HTTP method issue was confirmed.

Two operational follow-ups remain: protecting the Edge resolver without interrupting the already-deployed Cloudflare Worker, and confirming distributed IP-based throttling at the Cloudflare edge. Neither requires accepting an immediate internal-network compromise risk after the SSRF remediation.

## Scope and methodology

### In scope

- Public console, authentication, account creation, OAuth entry points, health endpoints, and static assets
- Session, CSRF, CSP, CORS, TLS, HTTP method, and security-header behavior
- Project authorization and billing-sensitive routes
- Edge origin proxy and resolver
- Uptime checks and monitoring notification webhooks
- Bachs, Polar, GitHub, and Resend webhook verification
- Email delivery error handling
- Ruby and production JavaScript dependencies
- Secret scanning and static application analysis

### Methods

- Manual source review and trust-boundary tracing
- Isolated exploit regression tests against PostgreSQL-backed application builds
- OWASP ZAP passive baseline against production (19 discovered URLs)
- Brakeman static analysis
- `bundler-audit` against the Ruby advisory database
- `npm audit --omit=dev`
- Gitleaks full-history scan with redacted output
- Safe production probes for headers, cookies, CORS, methods, redirects, health endpoints, and TLS versions

### Safety constraints

No production load testing, destructive mutation, credential spraying, account takeover attempt, cloud-metadata request, or third-party infrastructure attack was performed. Authenticated exploit validation was conducted against the isolated local build.

## Findings

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| LR-SEC-001 | High | Server-side request forgery and DNS rebinding through Edge, uptime checks, and monitoring webhooks | Fixed |
| LR-SEC-002 | High | Known vulnerabilities in locked runtime dependencies and DOMPurify | Fixed |
| LR-SEC-003 | Medium | Edge proxy trusted spoofable forwarding/hop headers and had unbounded bodies | Fixed |
| LR-SEC-004 | Medium | Outbound checks and webhooks could buffer unbounded response bodies | Fixed |
| LR-SEC-005 | Medium | Resend error bodies could disclose request details or secrets in logs | Fixed |
| LR-SEC-006 | Medium | Public CSP unnecessarily allowed inline styles and Intercom origins | Fixed for public pages |
| LR-SEC-007 | Low | Security headers were inconsistent on assets and redirects | Fixed |
| LR-SEC-008 | Low | Development inference HTTPS explicitly disabled certificate verification | Fixed |
| LR-SEC-009 | Medium | Public Edge resolver reveals origin configuration for known Edge hostnames | Open; coordinated rollout required |
| LR-SEC-010 | Low | Application-level distributed IP throttling was not verified | Open; verify Cloudflare policy |
| LR-SEC-011 | Informational | Cross-origin isolation headers are not enabled | Accepted compatibility trade-off |
| LR-SEC-012 | Informational | Development-only npm toolchain advisories remain | Follow-up |

### LR-SEC-001 — SSRF and DNS rebinding

**Affected paths:** Edge service creation and proxying, uptime checks, monitoring webhooks.

Previously, these features accepted HTTP(S) URLs and connected with ordinary `Net::HTTP` calls. A project user could target loopback, RFC1918, link-local, IPv6-local, cloud metadata, or an attacker-controlled hostname that changed to a private address after validation.

**Remediation:**

- Require HTTP(S) URLs with no credentials or fragments and a maximum length.
- Resolve all addresses and reject a hostname if any answer is private, loopback, link-local, mapped, multicast, documentation, transition, reserved, or metadata-related.
- Reject local hostname suffixes and IPv6 zone identifiers.
- Re-resolve for every outbound operation and pin `Net::HTTP` to the validated address using `ipaddr=` while preserving the hostname for TLS verification.
- Disable environment-proxy inheritance for protected requests.
- Do not follow redirects.
- Revalidate persisted values at execution time, not only during form submission.

### LR-SEC-002 — Vulnerable dependencies

The locked Ruby graph contained current advisories affecting `concurrent-ruby`, `excon`, `faraday`, `faraday-net_http`, `json`, `net-imap`, `nokogiri`, `oauth2`, `puma`, and `websocket-driver`. DOMPurify 3.4.0 also had current XSS advisories.

**Remediation:** Runtime dependencies were updated to patched releases, including Puma 7.2.1, OAuth2 2.0.25, Nokogiri 1.19.4, and websocket-driver 0.8.2. DOMPurify was updated to 3.4.11 with a matching SHA-256 SRI value. Final `bundler-audit` reports no known vulnerabilities, and the production npm graph reports zero vulnerabilities.

### LR-SEC-003 — Edge proxy hardening

The fallback Edge proxy forwarded user-supplied forwarding headers, did not account for headers named by `Connection`, mapped unsupported methods to GET, and buffered request/response bodies without a limit.

**Remediation:**

- Allow only GET, HEAD, POST, PUT, PATCH, DELETE, and OPTIONS; return 405 otherwise.
- Strip standard hop-by-hop headers, proxy authentication headers, headers named by `Connection`, and spoofable forwarding headers.
- Generate trusted forwarding metadata.
- Enforce a 16 MiB request and response limit.
- Stream and cap upstream responses rather than calling an unbounded `.body` accessor.
- Return a generic 502 and log only the exception class.

### LR-SEC-004 — Outbound response buffering

Uptime GET checks and monitoring webhook deliveries did not need response bodies but allowed `Net::HTTP` to buffer them. A public attacker-controlled endpoint could consume excessive worker memory.

**Remediation:** Both paths now use block-form requests and retain only response metadata.

### LR-SEC-005 — Resend error disclosure

Provider rejection bodies could include email addresses, payload fragments, or credentials and were included in exception messages consumed by application logging.

**Remediation:** Only safe structured provider fields (`name`, `type`, `code`, and `statusCode`) are retained. Non-JSON bodies are replaced with `[redacted]`.

### LR-SEC-006 and LR-SEC-007 — Browser policy and headers

Intercom's CSP sources and `style-src 'unsafe-inline'` were globally enabled, including login and account-creation pages. Static assets and OAuth redirects did not consistently receive HSTS, `X-Content-Type-Options`, Permissions Policy, Referrer Policy, and Cross-Origin Resource Policy.

**Remediation:** Intercom CSP exceptions are now added only to authenticated console requests. Public pages no longer allow inline styles. Universal response headers are applied to assets and redirects, while dynamic HTML/API responses retain `Cache-Control: no-store`.

Authenticated pages still permit inline styles when Intercom is enabled because the current messenger integration requires them. Removing that exception requires replacing or isolating the widget.

### LR-SEC-008 — Development TLS verification

Inference endpoint HTTPS requests explicitly set `VERIFY_NONE` in development. The branch was not active in production, but it trained unsafe behavior and exposed development credentials to a local network attacker.

**Remediation:** HTTPS certificate verification is always `VERIFY_PEER`.

### LR-SEC-009 — Edge resolver origin disclosure

`/edge-runtime/resolve` returns an Edge service's public origin URL and cache/TLS configuration to anyone who knows its Edge hostname. This can help an attacker bypass the Cloudflare edge and target the origin directly.

The resolver cannot be made mandatory-token-only in the application release alone: the currently deployed Cloudflare Worker does not send such a token, and changing the endpoint first would interrupt every Edge service. A coordinated rollout should:

1. Add a dedicated resolver secret to the application and Worker.
2. Deploy the Worker while the endpoint accepts both modes.
3. Confirm all Worker requests include the secret.
4. Enforce the secret and remove unauthenticated compatibility.
5. Prefer Cloudflare KV or signed, short-lived configuration responses for the longer term.

### LR-SEC-010 — Distributed request throttling

Rodauth account lockout, MFA, audit logging, and Turnstile account-creation checks are enabled. An application-level, distributed IP throttle for login and personal-access-token failures was not found. Cloudflare may provide this control, but its production policy was outside the available credentials and could not be verified.

**Recommendation:** Confirm Cloudflare WAF/rate-limit rules for login, reset/unlock, OAuth initiation, and repeated API authentication failures. Alert on high-cardinality login failures to avoid account-lockout abuse.

### LR-SEC-011 — Cross-origin isolation

ZAP reported missing COOP/COEP. Enabling `Cross-Origin-Embedder-Policy: require-corp` would currently break third-party Turnstile, Intercom, status embeds, and CDN assets unless every resource is made CORS/CORP compatible. This is accepted as an informational hardening opportunity, not a confirmed exploit.

### LR-SEC-012 — Development dependency advisories

The production npm graph is clean. The full development graph reports advisories in build/test tooling. These packages are not shipped by the application container.

**Recommendation:** Upgrade the development toolchain in a separate lockfile-focused change and rerun frontend build/lint checks.

## Verified existing controls

- Argon2 password hashing, MFA/OTP/WebAuthn/recovery codes, account lockout, and authentication audit logs
- Secure, HttpOnly, SameSite=Lax production session cookies
- CSRF protection on web forms and route actions
- Project-scoped authorization on reviewed resource routes
- Strict CSP with `default-src 'none'`, `base-uri 'none'`, and `frame-ancestors 'none'`
- HSTS, frame denial, and MIME-sniffing prevention
- No permissive CORS response on tested endpoints
- TRACE rejected with 405 and TLS 1.0 rejected
- HMAC/timing-safe verification for Bachs, GitHub, Polar/Svix, and Resend webhooks
- Parameterized Sequel database access on reviewed paths
- Public health endpoints expose status only; authenticated API health remains protected

## Tool results

- **OWASP ZAP passive production baseline:** 0 high, 1 medium, 7 low, 6 informational before remediation. The medium alert was globally scoped `style-src 'unsafe-inline'`; public-page scope is fixed in this change. Header alerts are addressed by universal response headers.
- **Brakeman:** no SQL injection, command injection, mass assignment, template injection, or strong-confidence XSS finding. The TLS bypass and verb ambiguity were remediated. Remaining weak eval warnings are framework metaprogramming over developer-defined identifiers.
- **Ruby advisory audit:** no vulnerabilities after dependency updates.
- **Production npm audit:** zero vulnerabilities.
- **Gitleaks:** 17 redacted matches were reviewed as generated/test fixture material; no live credential was confirmed.
- **Targeted regression suite:** SSRF, rebinding, private-address variants, Edge resolver/proxy, forwarding-header replacement, email redaction, CSP, and browser-header tests pass in the isolated PostgreSQL-backed image.

## Residual limitations

- The passive production scan covered only unauthenticated URLs and intentionally did not crawl customer resources.
- Cloudflare, Render, provider control planes, and customer origins were not attacked.
- Business-logic authorization was source-reviewed and regression-tested on the changed surfaces, not exhaustively fuzzed for every route permutation.
- Availability behavior under volumetric abuse requires controlled load testing in a non-production environment.

## Retest guidance

After deployment:

1. Re-run the passive ZAP baseline and confirm the public-page CSP medium alert is gone.
2. Confirm HSTS and `nosniff` on brand assets and OAuth redirects.
3. Confirm unauthenticated CSP has no Intercom sources or `unsafe-inline`.
4. Confirm private, loopback, metadata, mapped IPv6, and mixed-DNS targets are rejected by Edge, uptime, and webhook forms.
5. Complete the coordinated Edge resolver secret rollout.
6. Review Cloudflare rate-limit events and application authentication-failure alerts after one week.
