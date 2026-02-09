#!/bin/bash
#
# Nettoyage de la démo Fraud Detection Feature Store
#
set -euo pipefail

NAMESPACE="fraud-detection-ml"

echo "=== Suppression de toutes les ressources de la démo ==="
echo ""
read -p "Supprimer le namespace ${NAMESPACE} et toutes ses ressources ? (y/N) " confirm
if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    echo "Annulé."
    exit 0
fi

echo "Suppression du namespace ${NAMESPACE}..."
oc delete namespace "${NAMESPACE}" --wait=true

echo ""
echo "=== Nettoyage terminé ==="
