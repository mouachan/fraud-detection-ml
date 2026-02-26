#!/bin/bash
#
# Workaround s3fs + feast apply + feast materialize-incremental
# A lancer après le déploiement (deploy.sh ou helm install)
#
set -euo pipefail

NAMESPACE="${1:-fraud-detection-ml}"

echo "=== Feast Init (workaround s3fs) ==="
echo ""

echo "Attente du pod Feast..."
oc wait --for=condition=ready pod -l feast.dev/name=fraud-features -n "${NAMESPACE}" --timeout=300s

FEAST_POD=$(oc get pod -l feast.dev/name=fraud-features -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
echo "Pod Feast : ${FEAST_POD}"

echo ""
echo "[1/3] Installation de s3fs dans /tmp/pip..."
oc exec "${FEAST_POD}" -c online -n "${NAMESPACE}" -- \
  bash -c "pip install --target=/tmp/pip s3fs 2>&1 | tail -1"

echo "[2/3] feast apply..."
oc exec "${FEAST_POD}" -c online -n "${NAMESPACE}" -- \
  bash -c "PYTHONPATH=/tmp/pip feast -c /feast-data/fraud_detection/feature_repo apply"

echo "[3/3] feast materialize-incremental..."
oc exec "${FEAST_POD}" -c online -n "${NAMESPACE}" -- \
  bash -c "PYTHONPATH=/tmp/pip feast -c /feast-data/fraud_detection/feature_repo materialize-incremental \$(date -u +%Y-%m-%dT%H:%M:%S)"

echo ""
echo "=== Vérification ==="
oc get featurestore -n "${NAMESPACE}"
echo ""
oc get pods -n "${NAMESPACE}"
echo ""
FEAST_UI_ROUTE=$(oc get route feast-fraud-features-ui -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "non disponible")
echo "Feature Store UI : https://${FEAST_UI_ROUTE}"
echo ""
echo "=== Feast Init terminé ==="
