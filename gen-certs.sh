#!/usr/bin/env bash
# Self-signed CA + server cert for the demo (netns server addresses).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p certs && cd certs
openssl req -x509 -newkey rsa:2048 -keyout ca-key.pem -out ca.pem \
  -days 365 -nodes -subj "/CN=mpquic-demo-ca" 2>/dev/null
openssl req -newkey rsa:2048 -keyout server-key.pem -out server.csr \
  -nodes -subj "/CN=mpquic-demo-server" 2>/dev/null
cat > san.cnf <<'SAN'
subjectAltName = DNS:localhost, IP:127.0.0.1, IP:10.10.0.2, IP:10.20.0.2
SAN
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca-key.pem \
  -CAcreateserial -out server.pem -days 365 -extfile san.cnf 2>/dev/null
rm -f server.csr san.cnf
echo "certs written to $(pwd)"
