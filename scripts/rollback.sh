#!/bin/bash
set -e

# ==============================================================================
# Emergency Rollback Script for Checkout API Service
# Reverts deployment from candidate v2.4 to known-good stable version v2.3
# ==============================================================================

TARGET_NAMESPACE="checkout-system"
DEPLOYMENT_NAME="checkout-api"
STABLE_VERSION="v2.3"
STABLE_IMAGE="kalvium/checkout-api:v2.3"

echo "======================================================="
echo "🚨 INITIATING EMERGENCY ROLLBACK: Checkout API -> ${STABLE_VERSION}"
echo "Target Namespace:  ${TARGET_NAMESPACE}"
echo "Deployment:        ${DEPLOYMENT_NAME}"
echo "Stable Image:      ${STABLE_IMAGE}"
echo "Timestamp:         $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "======================================================="

# Step 1: Check if deployment exists in target namespace
echo "[1/4] Verifying deployment presence in namespace ${TARGET_NAMESPACE}..."
if ! kubectl get deployment "${DEPLOYMENT_NAME}" -n "${TARGET_NAMESPACE}" > /dev/null 2>&1; then
    echo "❌ Error: Deployment ${DEPLOYMENT_NAME} not found in namespace ${TARGET_NAMESPACE}!"
    exit 1
fi

# Step 2: Perform rollout undo or explicit image revert
echo "[2/4] Executing rollback to ${STABLE_IMAGE}..."
kubectl set image deployment/"${DEPLOYMENT_NAME}" "${DEPLOYMENT_NAME}=${STABLE_IMAGE}" -n "${TARGET_NAMESPACE}" --record

# Patch label metadata
kubectl patch deployment "${DEPLOYMENT_NAME}" -n "${TARGET_NAMESPACE}" --type='json' -p='[
  {"op": "replace", "path": "/metadata/labels/version", "value": "'"${STABLE_VERSION}"'"},
  {"op": "replace", "path": "/spec/template/metadata/labels/version", "value": "'"${STABLE_VERSION}"'"}
]'

# Step 3: Wait for rollout to finish
echo "[3/4] Waiting for rollout status confirmation (Timeout: 120s)..."
kubectl rollout status deployment/"${DEPLOYMENT_NAME}" -n "${TARGET_NAMESPACE}" --timeout=120s

# Step 4: Verification smoke check
echo "[4/4] Verifying pod status and active version..."
kubectl get pods -n "${TARGET_NAMESPACE}" -l app="${DEPLOYMENT_NAME}"

echo "======================================================="
echo "✅ Rollback to ${STABLE_VERSION} successfully completed!"
echo "Next step: Inspect application logs and announce resolution."
echo "======================================================="
