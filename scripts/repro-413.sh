#!/bin/bash
# Reproduce the n8n 413 / webhook-500 behaviour against a running n8n (and optionally an nginx in front of it).
#
# Prerequisites: a published workflow whose Webhook node listens on POST /webhook/big-body with
# "Respond: Immediately" (scripts/wf-big.json; import with `n8n import:workflow --input=wf-big.json`,
# then `n8n publish:workflow --id=bigBody0000001`, then restart n8n).
#
# Usage: ./repro-413.sh http://localhost:5678            # n8n directly
#        ./repro-413.sh http://localhost:8091            # through nginx (configs/nginx/request-entity-too-large)
set -u
BASE="${1:-http://localhost:5678}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$TMP" <<'EOF'
import sys
d = sys.argv[1]
for name, size in (('big2.json', 2 * 1024 * 1024), ('big17.json', 17 * 1024 * 1024)):
    pre, post = '{"data":"', '"}'
    open(f'{d}/{name}', 'w').write(pre + 'x' * (size - len(pre) - len(post)) + post)
open(f'{d}/file20.bin', 'wb').write(b'\0' * (20 * 1024 * 1024))
EOF

echo "## $(date -u +%FT%TZ) base $BASE"
for f in big2.json big17.json; do
  echo "\$ POST $f (JSON) -> /webhook/big-body"
  curl -s -w ' %{http_code}' -H 'Content-Type: application/json' --data-binary @"$TMP/$f" "$BASE/webhook/big-body"; echo
done
echo "\$ POST big17.json (JSON) -> /rest/login"
curl -s -w ' %{http_code}' -H 'Content-Type: application/json' --data-binary @"$TMP/big17.json" "$BASE/rest/login"; echo
echo "\$ POST file20.bin (multipart form-data) -> /webhook/big-body"
curl -s -w ' %{http_code}' -F "upload=@$TMP/file20.bin" "$BASE/webhook/big-body"; echo
