#!/bin/bash
#
# Déploiement de la démo Fraud Detection Feature Store
# Red Hat OpenShift AI 3.2
#
# Prérequis :
#   - oc CLI connecté au cluster OpenShift
#   - OpenShift AI installé avec le Feast Operator activé
#     (DataScienceCluster -> feastoperator.managementState: Managed)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="fraud-detection-ml"

echo "=== Fraud Detection Feature Store - Déploiement ==="
echo ""

# 1. Namespace
echo "[1/7] Création du namespace..."
oc apply -f "${SCRIPT_DIR}/00-namespace.yaml"

# 2. PostgreSQL (online store)
echo "[2/7] Déploiement de PostgreSQL..."
oc apply -f "${SCRIPT_DIR}/01-postgres.yaml"
echo "  Attente du pod PostgreSQL..."
oc rollout status deployment/postgres -n "${NAMESPACE}" --timeout=120s

# 3. MinIO (registry S3)
echo "[3/7] Déploiement de MinIO..."
oc apply -f "${SCRIPT_DIR}/02-minio.yaml"
echo "  Attente du pod MinIO..."
oc rollout status deployment/minio -n "${NAMESPACE}" --timeout=120s

# 4. Secrets
echo "[4/7] Création des secrets..."
oc apply -f "${SCRIPT_DIR}/03-secrets.yaml"

# 5. Bucket MinIO
echo "[5/7] Création du bucket feast-registry dans MinIO..."
oc apply -f "${SCRIPT_DIR}/04-minio-bucket-job.yaml"
echo "  Attente de la fin du job..."
oc wait --for=condition=complete job/minio-create-bucket -n "${NAMESPACE}" --timeout=120s

# 6. RBAC
echo "[6/7] Configuration du RBAC..."
oc apply -f "${SCRIPT_DIR}/06-rbac.yaml"

# 7. FeatureStore CR
echo "[7/7] Déploiement du FeatureStore..."
oc apply -f "${SCRIPT_DIR}/05-featurestore.yaml"

echo ""
echo "  Attente du démarrage du pod Feast..."
sleep 10
oc wait --for=condition=ready pod -l feast.dev/name=fraud-features -n "${NAMESPACE}" --timeout=300s 2>/dev/null || true

echo ""
echo "=== Vérification ==="
echo ""
oc get featurestore -n "${NAMESPACE}"
echo ""
oc get pods -n "${NAMESPACE}"
echo ""

FEAST_UI_ROUTE=$(oc get route feast-fraud-features-ui -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "non disponible")
echo "Feature Store UI : https://${FEAST_UI_ROUTE}"
echo ""
echo "=== Déploiement terminé ==="
