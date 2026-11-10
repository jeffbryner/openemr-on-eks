#!/usr/bin/env bash
# Retrieve OpenEMR access details on demand from the live cluster.
#
# Kubernetes Secrets are the single source of truth for credentials (deploy.sh
# no longer writes any plaintext credential file). This script reads those
# secrets and the Ingress-provisioned ALB URL so you never have to chase a
# stale openemr-credentials*.txt again.
#
# Usage:
#   scripts/get-credentials.sh            # print URL + all credentials
#   scripts/get-credentials.sh --url      # print only the site URL
#   scripts/get-credentials.sh --password # print only the admin password
#   NAMESPACE=myns scripts/get-credentials.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-openemr}"
INGRESS_NAME="${INGRESS_NAME:-openemr-ingress}"
MODE="all"

case "${1:-}" in
  --url)      MODE="url" ;;
  --password) MODE="password" ;;
  --help|-h)
    echo "Usage: $0 [--url|--password]"
    echo "  (no args)    print site URL and all credentials"
    echo "  --url        print only the site URL"
    echo "  --password   print only the admin password"
    echo "Environment: NAMESPACE (default: openemr)"
    exit 0
    ;;
  "") ;;
  *)
    echo "Unknown argument: $1 (try --help)" >&2
    exit 1
    ;;
esac

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "kubectl is not configured or the cluster is unreachable." >&2
  echo "Refresh your AWS credentials / kubeconfig and try again." >&2
  exit 1
fi

# Read a single key from a Kubernetes secret, base64-decoded. Empty if missing.
get_secret() {
  local secret="$1" key="$2"
  kubectl get secret "$secret" -n "$NAMESPACE" \
    -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d 2>/dev/null || true
}

# Resolve the public site URL from the Ingress ALB hostname.
get_url() {
  local host
  host=$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -z "$host" ]; then
    return 1
  fi
  # No ACM cert/domain on this setup -> ALB serves HTTP only.
  echo "http://${host}/interface/login/login.php"
}

ADMIN_PASSWORD=$(get_secret openemr-app-credentials admin-password)

if [ "$MODE" = "password" ]; then
  if [ -z "$ADMIN_PASSWORD" ]; then
    echo "Admin password not found in secret openemr-app-credentials (namespace: $NAMESPACE)." >&2
    exit 1
  fi
  echo "$ADMIN_PASSWORD"
  exit 0
fi

if [ "$MODE" = "url" ]; then
  if ! URL=$(get_url); then
    echo "Ingress '$INGRESS_NAME' has no ALB hostname yet (namespace: $NAMESPACE)." >&2
    echo "The ALB may still be provisioning - retry in 2-3 minutes." >&2
    exit 1
  fi
  echo "$URL"
  exit 0
fi

# Full report
ADMIN_USER=$(get_secret openemr-app-credentials admin-user)
DB_PASSWORD=$(get_secret openemr-db-credentials mysql-password)
REDIS_PASSWORD=$(get_secret openemr-redis-credentials redis-password)
URL=$(get_url || echo "")

echo "OpenEMR Access Details (namespace: $NAMESPACE)"
echo "=============================================="
if [ -n "$URL" ]; then
  echo "Site URL:        $URL"
else
  echo "Site URL:        (Ingress ALB not provisioned yet - retry in 2-3 min)"
fi
echo "Admin Username:  ${ADMIN_USER:-admin}"
echo "Admin Password:  ${ADMIN_PASSWORD:-<not found>}"
echo "DB Password:     ${DB_PASSWORD:-<not found>}"
echo "Redis Password:  ${REDIS_PASSWORD:-<not found>}"
echo ""
echo "Source of truth: Kubernetes Secrets (no plaintext files are written)."
