#!/bin/bash
#
# Déploiement de la démo Fraud Detection Feature Store
# Red Hat OpenShift AI 3.2
#
# Prérequis :
#   - oc CLI connecté au cluster OpenShift
#   - OpenShift AI installé avec le Feast Operator activé
#     (DataScienceCluster -> feastoperator.managementState: Managed)
#   - Remplacer les placeholders <CHANGEZ_MOI> dans 01-secrets.yaml
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="fraud-detection-ml"

echo "=== Fraud Detection Feature Store - Déploiement ==="
echo ""

# 1. Namespace
echo "[1/10] Création du namespace..."
oc apply -f "${SCRIPT_DIR}/00-namespace.yaml"

# 2. Secrets (avant les deployments qui en dépendent)
echo "[2/10] Création des secrets..."
oc apply -f "${SCRIPT_DIR}/01-secrets.yaml"

# 3. RBAC
echo "[3/10] Configuration du RBAC..."
oc apply -f "${SCRIPT_DIR}/02-rbac.yaml"

# 4. MinIO (registry S3 + offline store)
echo "[4/10] Déploiement de MinIO..."
oc apply -f "${SCRIPT_DIR}/03-minio.yaml"
echo "  Attente du pod MinIO..."
oc rollout status deployment/minio -n "${NAMESPACE}" --timeout=120s

# 5. Bucket MinIO
echo "[5/10] Création du bucket feast-registry dans MinIO..."
oc delete job minio-create-bucket -n "${NAMESPACE}" --ignore-not-found
oc apply -f "${SCRIPT_DIR}/04-minio-bucket-job.yaml"
echo "  Attente de la fin du job..."
oc wait --for=condition=complete job/minio-create-bucket -n "${NAMESPACE}" --timeout=120s

# 6. PostgreSQL (online store)
echo "[6/10] Déploiement de PostgreSQL..."
oc apply -f "${SCRIPT_DIR}/05-postgres.yaml"
echo "  Attente du pod PostgreSQL..."
oc rollout status deployment/postgres -n "${NAMESPACE}" --timeout=120s

# 7. Données de démo dans PostgreSQL
echo "[7/10] Chargement des données de démo dans PostgreSQL..."
oc delete job init-feast-data -n "${NAMESPACE}" --ignore-not-found
oc apply -f "${SCRIPT_DIR}/06-init-data-job.yaml"
echo "  Attente de la fin du job..."
oc wait --for=condition=complete job/init-feast-data -n "${NAMESPACE}" --timeout=120s

# 8. FeatureStore CR
echo "[8/10] Déploiement du FeatureStore..."
oc apply -f "${SCRIPT_DIR}/07-featurestore.yaml"

echo ""
echo "  Attente du démarrage du pod Feast..."
sleep 10
oc wait --for=condition=ready pod -l feast.dev/name=fraud-features -n "${NAMESPACE}" --timeout=300s 2>/dev/null || true

# 9. Données Parquet dans MinIO
echo "[9/10] Upload des données Parquet dans MinIO..."
oc delete job init-parquet-data -n "${NAMESPACE}" --ignore-not-found
oc apply -f "${SCRIPT_DIR}/08-parquet-data-job.yaml"
echo "  Attente de la fin du job..."
oc wait --for=condition=complete job/init-parquet-data -n "${NAMESPACE}" --timeout=180s

# 10. Workaround s3fs + feast apply + feast materialize-incremental
echo "[10/10] Installation de s3fs et initialisation Feast (apply + materialize)..."

# Trouver le pod Feast (online container)
FEAST_POD=$(oc get pod -l feast.dev/name=fraud-features -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
echo "  Pod Feast : ${FEAST_POD}"

# Installer s3fs dans /tmp/pip (workaround : l'image odh-feature-server-rhel9 ne contient pas s3fs)
echo "  Installation de s3fs dans /tmp/pip..."
oc exec "${FEAST_POD}" -c online -n "${NAMESPACE}" -- \
  bash -c "pip install --target=/tmp/pip s3fs 2>&1 | tail -1"

# feast apply avec PYTHONPATH pour trouver s3fs
echo "  Exécution de feast apply..."
oc exec "${FEAST_POD}" -c online -n "${NAMESPACE}" -- \
  bash -c "PYTHONPATH=/tmp/pip feast -c /feast-data/fraud_detection/feature_repo apply"

# feast materialize-incremental
echo "  Exécution de feast materialize-incremental..."
oc exec "${FEAST_POD}" -c online -n "${NAMESPACE}" -- \
  bash -c "PYTHONPATH=/tmp/pip feast -c /feast-data/fraud_detection/feature_repo materialize-incremental \$(date -u +%Y-%m-%dT%H:%M:%S)"

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
