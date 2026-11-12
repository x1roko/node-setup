#!/bin/bash
# Post-install self-check for a Remnanode + nginx selfsteal node.
# Verifies the anti-DPI hardening: 301, TLS 1.2/1.3, HSTS (incl. errors),
# unknown-SNI rejection, live fallback, and that node port 2222 is not open
# to the internet.
#
# Usage: ./verify.sh <domain> [ip]
#   ./verify.sh node1.example.com            # test via 127.0.0.1
#   ./verify.sh node1.example.com 1.2.3.4    # test the public address

set -u

DOMAIN="${1:-}"
IP="${2:-127.0.0.1}"
FAIL=0

if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 <domain> [ip]"
    exit 2
fi

ok()   { echo "  [OK]   $1"; }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
skip() { echo "  [SKIP] $1"; }

echo "== Self-check for $DOMAIN ($IP) =="

# 1. HTTP -> HTTPS redirect
CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 8 -H "Host: $DOMAIN" "http://$IP/" 2>/dev/null)
LOC=$(curl -sI -m 8 -H "Host: $DOMAIN" "http://$IP/" 2>/dev/null | grep -i '^location:' | tr -d '\r')
if [ "$CODE" = "301" ]; then ok "80 -> 301 ($LOC)"; else bad "80 -> $CODE (expected 301)"; fi

# 2. TLS versions
for v in tls1_2 tls1_3; do
    if echo | timeout 8 openssl s_client -connect "$IP:443" -servername "$DOMAIN" -"$v" 2>/dev/null | grep -q "New, TLS"; then
        ok "$v accepted"
    else
        bad "$v rejected"
    fi
done
if echo | timeout 8 openssl s_client -connect "$IP:443" -servername "$DOMAIN" -tls1_1 2>&1 | grep -qi "no protocols available"; then
    ok "TLS 1.1 disabled"
else
    bad "TLS 1.1 still accepted"
fi

# 3. Certificate validity
if echo | timeout 8 openssl s_client -connect "$IP:443" -servername "$DOMAIN" 2>/dev/null | grep -q "Verify return code: 0 (ok)"; then
    ok "certificate chain verifies"
else
    bad "certificate does not verify (expired/self-signed?)"
fi

# 4. HSTS on a normal response and on an error response
H200=$(curl -skI -m 8 --resolve "$DOMAIN:443:$IP" "https://$DOMAIN/" 2>/dev/null | grep -i '^strict-transport-security:' | tr -d '\r')
H404=$(curl -skI -m 8 --resolve "$DOMAIN:443:$IP" "https://$DOMAIN/.healthcheck-$RANDOM" 2>/dev/null | grep -i '^strict-transport-security:' | tr -d '\r')
[ -n "$H200" ] && ok "HSTS on 200 ($H200)" || bad "no HSTS on 200"
[ -n "$H404" ] && ok "HSTS on 404" || bad "no HSTS on 404 (add_header without 'always'?)"

# 5. Fallback actually serves a site
BODY_CODE=$(curl -sk -o /dev/null -w '%{http_code}' -m 10 --resolve "$DOMAIN:443:$IP" "https://$DOMAIN/" 2>/dev/null)
BODY_LEN=$(curl -sk -m 10 --resolve "$DOMAIN:443:$IP" "https://$DOMAIN/" 2>/dev/null | wc -c)
if [ "$BODY_CODE" = "200" ] && [ "$BODY_LEN" -gt 500 ]; then
    ok "fallback serves content ($BODY_CODE, ${BODY_LEN} bytes)"
else
    bad "fallback looks broken ($BODY_CODE, ${BODY_LEN} bytes) — 502/empty page is a fingerprint"
fi

# 6. Unknown SNI must be rejected
RND="probe-$RANDOM.example"
if echo | timeout 8 openssl s_client -connect "$IP:443" -servername "$RND" 2>&1 | grep -qi "unrecognized name"; then
    ok "unknown SNI rejected (alert 112)"
else
    bad "unknown SNI is served — default_server with ssl_reject_handshake missing"
fi

# 7. Node port 2222 must be closed to the world
if command -v ufw >/dev/null 2>&1; then
    LINE=$(ufw status 2>/dev/null | grep '2222' | head -1)
    if [ -z "$LINE" ]; then
        ok "2222 not allowed by ufw"
    elif echo "$LINE" | grep -q 'Anywhere'; then
        bad "2222 is open to the world: $LINE"
    else
        ok "2222 limited: $LINE"
    fi
else
    skip "ufw not found, cannot check port 2222"
fi

echo "------------------------------------------------"
if [ "$FAIL" -eq 0 ]; then
    echo "RESULT: all checks passed"
else
    echo "RESULT: $FAIL check(s) failed"
fi
exit "$FAIL"
