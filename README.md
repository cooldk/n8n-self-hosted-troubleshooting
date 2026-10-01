# n8n self-hosted troubleshooting: six errors, reproduced

Six errors that self-hosted n8n users run into, each triggered on purpose on a real n8n instance. For each one
you get the message as you will see it, the exact config that caused it, the log line, and the change that made it go away.
The nginx and env files we actually used are in [`configs/`](configs/).

> Written by the flowtemplates.app maintainers; reproduced on local n8n 2.41.3 on 30 September 2026, and the 413 section
> again on local n8n 2.41.5 on 1 October 2026. Each section links to a longer write-up on flowtemplates.app.

## How these were reproduced (read this first)

- **n8n installed from npm, not the Docker image.** Docker Desktop could not pull images on our machine, so every run
  used `npm install n8n@<version>` on Node 24 with `NODE_ENV=production`, the same value the official image's Dockerfile
  sets. Some behaviour only appears in production mode (noted below). Docker-specific paths (`/home/node/.n8n`) come from
  n8n's Dockerfile and docs. We did not observe them inside a container.
- **Real nginx** (1.31.3) for the proxy scenarios, run from a throwaway prefix with `daemon off;`.
- **No production data, no third-party services.** Workflows were imported with `n8n import:workflow`, published with
  `n8n publish:workflow`, and called with `curl`. The editor-side scenarios used a local test owner account on a
  throwaway instance.
- Environment: [`configs/env/local-repro.env`](configs/env/local-repro.env).

Newest n8n when this was written: **2.41.5** stable, 2.42.2 beta (npm, 1 October 2026). The GitHub release notes for
2.41.4 through 2.42.2 mention no change to any of the six areas below. Only the 413 section was re-run on 2.41.5.

---

## 1. `Mismatching encryption keys` · `Deployment key 'signing.hmac' cannot be read with this instance encryption key` · `Credentials could not be decrypted`

**Symptom.** n8n refuses to start, or starts and then fails every node that uses a credential.

**Tested on.** n8n 2.41.3, 30 September 2026.

**What caused each one.**

| Message | When | Cause we used to trigger it |
|---|---|---|
| `Mismatching encryption keys. The encryption key in the settings file …/.n8n/config does not match the N8N_ENCRYPTION_KEY env var.` | `n8n start` and every CLI command | `N8N_ENCRYPTION_KEY` set to a value different from `encryptionKey` in the existing `.n8n/config` |
| `Error: Deployment key 'signing.hmac' cannot be read with this instance encryption key` then `Exiting due to an error.` | Right after `n8n ready on ::, port …` | Swapped the key in a working instance's config file (database created under the old key) |
| `Credentials could not be decrypted. The likely reason is that a different "encryptionKey" was used to encrypt the data.` + `error:1C800064:Provider routines::bad decrypt` | When a node uses the credential; n8n itself starts fine | Plain `n8n export:credentials --all` from instance A, imported into instance B (import said `Successfully imported 1 credential.`) |

The webhook caller in the third case only saw `HTTP 500 {"message":"Error in workflow"}`.

**Fix.** Put the original key back: the `encryptionKey` value from the old `.n8n/config`. Pin it with
[`configs/env/encryption-key.env`](configs/env/encryption-key.env). To move credentials between instances, either export
with `--decrypted` (and delete the plain-text file afterwards), or start the new instance with the old key *before*
importing. Both worked on our instance. Workflows are not encrypted with this key: with the wrong key in place,
`n8n export:workflow --all` still reported `Successfully exported 2 workflows.`

n8n's key-rotation feature (`N8N_ENV_FEAT_ENCRYPTION_KEY_ROTATION`) does not change `N8N_ENCRYPTION_KEY`. The docs call
that the master key that "never changes" and rotate a separate data key under it.

Write-up: https://flowtemplates.app/n8n-encryption-key-error/

---

## 2. `413 Request Entity Too Large` · `PayloadTooLargeError: request entity too large` · webhook answers 500

**Symptom.** Large requests to n8n fail. Which status you get depends on which layer refused the body.

**Tested on.** n8n 2.41.3 (30 September 2026) and n8n 2.41.5 + nginx 1.31.3 (1 October 2026). Same results on both n8n versions.

**Config.** Workflow [`scripts/wf-big.json`](scripts/wf-big.json) (Webhook node, `POST /webhook/big-body`, respond immediately);
nginx [`configs/nginx/request-entity-too-large/nginx.conf`](configs/nginx/request-entity-too-large/nginx.conf):
port 8091 with no `client_max_body_size` (nginx default `1m`), port 8092 with `client_max_body_size 32m`.
Script: [`scripts/repro-413.sh`](scripts/repro-413.sh).

| Request | n8n at default (`N8N_PAYLOAD_SIZE_MAX` unset = 16 MiB) | n8n with `N8N_PAYLOAD_SIZE_MAX=32` |
|---|---|---|
| 17 MiB JSON → n8n webhook directly | **500** `{"code":0,"message":"There was a problem executing the workflow"}` | 200 `{"message":"Workflow was started"}` |
| 17 MiB JSON → n8n `/rest/login` directly | **413** `<pre>Payload Too Large</pre>` | 400 (body parsed, login validation) |
| 20 MiB file as multipart form-data → webhook | 200 (form-data has its own 200 MiB limit) | 200 |
| 2 MiB JSON → nginx :8091 (default 1m) → n8n | **413** nginx HTML page, `nginx/1.31.3` | **413**, same page: raising n8n's limit changes nothing here |
| 17 MiB JSON → nginx :8092 (`32m`) → n8n | 500 (n8n's own limit) | 200 |

**Log lines.**

```
# n8n (webhook case; the caller only sees the 500)
PayloadTooLargeError: request entity too large
    at readStream (…/node_modules/raw-body/index.js:163:17)
Error in handling webhook request POST /webhook/big-body: There was a problem executing the workflow

# nginx error.log (n8n logs nothing for these)
[error] … client intended to send too large body: 2097152 bytes, client: 127.0.0.1, server: , request: "POST /webhook/big-body HTTP/1.1"
```

**Fix.** Raise both limits: [`configs/env/payload-size.env`](configs/env/payload-size.env) (`N8N_PAYLOAD_SIZE_MAX`, read
only at startup, so recreate the container) and `client_max_body_size` in the nginx `server` or `location` that proxies to
n8n. For large files, send multipart form-data instead of base64 inside JSON.

Write-up: https://flowtemplates.app/n8n-request-entity-too-large/

---

## 3. `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR`

**Symptom.** n8n's log shows a `ValidationError` about `X-Forwarded-For` once a reverse proxy is in front.

**Tested on.** n8n 2.41.3, 30 September 2026.

**Config.** Any proxy that adds `X-Forwarded-For` (for example [`C-working.conf`](configs/nginx/connection-lost/C-working.conf))
**and** `NODE_ENV=production`. Without `NODE_ENV=production` the same request logged nothing, because the per-IP rate
limits are only attached in production mode.

**Log line** (first `POST /rest/login` carrying `X-Forwarded-For`; logged once per limiter):

```
ValidationError: The 'X-Forwarded-For' header is set but the Express 'trust proxy'
setting is false (default). This could indicate a misconfiguration which would
prevent express-rate-limit from accurately identifying users. See
https://express-rate-limit.github.io/ERR_ERL_UNEXPECTED_X_FORWARDED_FOR/ for more
information.
  code: 'ERR_ERL_UNEXPECTED_X_FORWARDED_FOR',
```

**Why it matters.** Until it is fixed, every user shares the proxy's IP in n8n's rate limits. Six password-reset token
checks from one IP returned `400 400 400 400 400 429` (`{"message":"Too many requests"}`).

**Fix.** `N8N_PROXY_HOPS=1` for one proxy (the number of proxies you control, never more):
[`configs/env/reverse-proxy.env`](configs/env/reverse-proxy.env). With it set, the same request logged nothing.

Write-up: https://flowtemplates.app/n8n-x-forwarded-for-trust-proxy/

---

## 4. `EACCES: permission denied, open '/home/node/.n8n/config'` · `SQLITE_READONLY`

**Symptom.** n8n exits at startup.

**Tested on.** n8n 2.41.3, 30 September 2026, by removing write permission from a test `.n8n` folder, its config file and its
database in turn (npm install; not inside the Docker image).

**Log lines** (our runs printed our local path; shown here with the Docker path):

```
No encryption key found - Auto-generating and saving to: /home/node/.n8n/config
Error: Failed to load command "start"
Error: EACCES: permission denied, open '/home/node/.n8n/config'
```

```
n8n ready on ::, port 5678
…
QueryFailedError: SQLITE_READONLY: attempt to write a readonly database
Exiting due to an error.
```

A world-readable config file is not an error on 2.41.3. n8n logged
`Permissions 0644 for n8n settings file … are too wide. Changing permissions to 0600..` and carried on.

**Fix.** The official image runs as the non-root user `node`. Give the mounted folder to that user. Check the uid first
(the current base image is Docker's hardened Node image, so do not assume):

```
docker run --rm --entrypoint id n8nio/n8n
sudo chown -R <uid>:<gid> ./n8n_data
```

Or use a named volume (`docker volume create n8n_data`, `-v n8n_data:/home/node/.n8n`), as n8n's Docker docs do. Change
the owner, not the mode: that folder holds the encryption key.

Write-up: https://flowtemplates.app/n8n-eacces-permission-denied/

---

## 5. Webhook URL shows `http://localhost:5678/…`

**Symptom.** The Webhook node shows a localhost URL. It works from the server itself and nowhere else.

**Tested on.** n8n 2.41.3, 30 September 2026, by loading n8n's own `UrlService` in a clean environment and printing the
base URLs it returns for each setting.

| Environment | Production webhook base | Test webhook base |
|---|---|---|
| (nothing set) | `http://localhost:5678/` | `http://localhost:5678/` |
| `N8N_HOST=n8n.example.com` | `http://n8n.example.com:5678/` | `http://n8n.example.com:5678/` |
| `N8N_EDITOR_BASE_URL=https://n8n.example.com/` | **`http://localhost:5678/`** | `https://n8n.example.com/` |
| `WEBHOOK_URL=https://n8n.example.com/` (deprecated) | `https://n8n.example.com/` | `https://n8n.example.com/` |
| `N8N_WEBHOOK_URL=https://n8n.example.com/` | `https://n8n.example.com/` | `https://n8n.example.com/` |

`N8N_EDITOR_BASE_URL` alone fixes only the test URL, so test runs work and the published workflow hands out localhost.
With the old name, 2.41.3 printed at startup:

```
WEBHOOK_URL -> Use N8N_WEBHOOK_URL instead, which sets the base URL for both test and production webhooks.
```

**Fix.** [`configs/env/reverse-proxy.env`](configs/env/reverse-proxy.env) (`N8N_WEBHOOK_URL` + `N8N_PROXY_HOPS`), recreate
the container, and re-send the URL anywhere you pasted the old one. We did not test third-party trigger re-registration.

Write-up: https://flowtemplates.app/n8n-webhook-url-localhost/

---

## 6. `Connection lost` · `Problem running workflow / Lost connection to the server` · `Origin header does NOT match the expected origin`

**Symptom.** The editor header shows "Connection lost", or manual executions fail with "Lost connection to the server".

**Tested on.** n8n 2.41.3 behind nginx 1.31.3, 30 September 2026. Four configurations, one per file in
[`configs/nginx/connection-lost/`](configs/nginx/connection-lost/). [`nginx.conf.as-left-2026-09-30`](configs/nginx/connection-lost/nginx.conf.as-left-2026-09-30)
is the original file as it was left at the end of the run, after the B-fix and D-default variations.

| Config | What the editor showed | Log |
|---|---|---|
| [A](configs/nginx/connection-lost/A-no-upgrade-headers.conf): no `Upgrade`/`Connection` headers | **No banner**: the editor never connected, so it never "lost" anything. Execute workflow → "Problem running workflow · Lost connection to the server"; no execution started | nginx: `GET /rest/push?pushRef=… 401`, retried after 1, 2, 4, 8, 15 s |
| [B](configs/nginx/connection-lost/B-host-left-default.conf): headers present, `Host` left at nginx default | "Connection lost" stays | `Origin header does NOT match the expected origin. (Origin: "http://localhost:8082" -> "localhost:8082", Expected: "n8n" -> "n8n", Protocol: "http")` |
| [C](configs/nginx/connection-lost/C-working.conf): working | No banner, runs work | `ERR_ERL_UNEXPECTED_X_FORWARDED_FOR`, because C forwards `X-Forwarded-For` and `N8N_PROXY_HOPS` was not set (fix in section 3) |
| [D](configs/nginx/connection-lost/D-short-read-timeout.conf): `proxy_read_timeout 20s` | Banner flashes about 1 s every 20–30 s | — |

The origin check only runs in production mode. n8n takes the expected host from `Forwarded`, then `X-Forwarded-Host`, then
`Host`. Sending `X-Forwarded-Host $host:$server_port` alone also fixed B. With nginx's default 60 s read timeout, the
connection stayed up for four minutes without a drop, so the default was not a problem in our test.

**Fix.** Use C. On a normal 443/80 listener, `Host $host` is enough. On a non-standard port, keep the port
(`$host:$server_port`). If the hosting layer cannot carry WebSockets at all,
[`configs/env/push-backend-sse.env`](configs/env/push-backend-sse.env) (`N8N_PUSH_BACKEND=sse`) made the editor connect and
the test workflow run behind config A.

Write-up: https://flowtemplates.app/n8n-connection-lost/

---

## Files

```
configs/env/local-repro.env            environment of the local reproductions
configs/env/encryption-key.env         section 1
configs/env/payload-size.env           section 2
configs/env/reverse-proxy.env          sections 3 and 5
configs/env/push-backend-sse.env       section 6
configs/nginx/request-entity-too-large/nginx.conf      section 2 (as run on 2026-10-01)
configs/nginx/connection-lost/{A,B,C,D}-*.conf         section 6, one server block each
configs/nginx/connection-lost/nginx.conf.as-left-2026-09-30
scripts/wf-big.json                    the Webhook workflow used in section 2
scripts/repro-413.sh                   section 2 requests (run against n8n 2.41.5 on 2026-10-01)
```

The configs and scripts are MIT licensed ([LICENSE](LICENSE)). If n8n's own documentation disagrees with anything here,
n8n's documentation wins. Corrections: support@flowtemplates.app.
