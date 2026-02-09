# Fraud Detection avec Feature Store sur OpenShift AI 3.2

Demonstration de **Feature Store** (Feast) sur **Red Hat OpenShift AI 3.2** pour un cas d'usage de detection de fraude bancaire en temps reel.

## Architecture

```
                        OpenShift AI 3.2
    ┌──────────────────────────────────────────────────┐
    │                                                  │
    │   ┌──────────────┐       ┌────────────────────┐  │
    │   │  Workbench    │       │  Feature Store     │  │
    │   │  (Notebook)   │──────▶│  (Feast Operator)  │  │
    │   └──────────────┘       └────────┬───────────┘  │
    │                                   │              │
    │              ┌────────────────────┼───────────┐  │
    │              ▼                    ▼           ▼  │
    │   ┌────────────────┐   ┌────────────────┐  ┌──┐ │
    │   │  Offline Store  │   │  Online Store   │  │S3│ │
    │   │   (DuckDB)     │   │  (PostgreSQL)   │  │  │ │
    │   │                │   │                 │  │  │ │
    │   │  Batch /       │   │  Real-time      │  │R │ │
    │   │  Training      │   │  Serving        │  │e │ │
    │   └────────────────┘   └────────────────┘  │g.│ │
    │                                            └──┘ │
    └──────────────────────────────────────────────────┘
```

### Composants

| Composant | Technologie | Role |
|-----------|-------------|------|
| **Offline Store** | DuckDB | Stockage des features historiques pour le training |
| **Online Store** | PostgreSQL 15 | Serving des features en temps reel (faible latence) |
| **Registry** | S3 / MinIO | Catalogue des metadonnees des features |
| **Feature Server** | Feast (RHOAI Operator) | API gRPC et REST pour servir les features |
| **UI** | Feast UI (RHOAI) | Interface web pour explorer les features |
| **Workbench** | Jupyter Notebook | Experimentation et entrainement du modele |

## Prerequis

- Cluster OpenShift 4.14+
- Red Hat OpenShift AI 3.2 installe
- Feast Operator active dans le DataScienceCluster :
  ```yaml
  spec:
    components:
      feastoperator:
        managementState: Managed
  ```
- CLI `oc` connecte au cluster
- StorageClass `gp3-csi` disponible (adapter dans les YAML si different)

## Structure du projet

```
fraud-detection-ml/
├── README.md
├── .gitignore
├── openshift/                          # Manifestes de deploiement
│   ├── 00-namespace.yaml               # Namespace avec label RHOAI
│   ├── 01-postgres.yaml                # PostgreSQL : PVC + Deployment + Service
│   ├── 02-minio.yaml                   # MinIO : PVC + Deployment + Service
│   ├── 03-secrets.yaml                 # Secrets (a personnaliser)
│   ├── 04-minio-bucket-job.yaml        # Job creation du bucket S3
│   ├── 05-featurestore.yaml            # FeatureStore CR (Feast)
│   ├── 06-rbac.yaml                    # ServiceAccount, Roles, RoleBindings
│   ├── deploy.sh                       # Script de deploiement automatise
│   └── cleanup.sh                      # Script de nettoyage
├── feature_repo/                       # Definitions Feast
│   ├── features.py                     # Entities, FeatureViews, On-Demand features
│   └── data/                           # Donnees Parquet (generees par le notebook)
└── notebooks/
    └── fraud_detection_feature_store_demo.ipynb
```

## Deploiement

### 1. Configurer les secrets

Avant de deployer, editez `openshift/03-secrets.yaml` et remplacez les valeurs `<CHANGEZ_MOI>` par vos propres credentials :

- `postgres-admin` : mot de passe PostgreSQL
- `postgres-creds` : connexion PostgreSQL pour Feast (le mot de passe doit correspondre)
- `minio-admin` : identifiants MinIO
- `minio-creds` : identifiants S3 pour Feast (doivent correspondre a minio-admin)

### 2. Deployer

```bash
./openshift/deploy.sh
```

Ce script deploie dans l'ordre :
1. Le namespace `fraud-detection-ml` avec le label `opendatahub.io/dashboard: "true"`
2. PostgreSQL (online store) avec volume persistant
3. MinIO (registry S3) avec volume persistant
4. Les secrets de connexion
5. Un Job pour creer le bucket `feast-registry` dans MinIO
6. Le RBAC (ServiceAccount et Roles pour le CronJob Feast)
7. Le FeatureStore CR qui declenche le Feast Operator

### 3. Verification

```bash
# Verifier le status du FeatureStore
oc get featurestore -n fraud-detection-ml

# Verifier les pods
oc get pods -n fraud-detection-ml

# Verifier les conditions
oc get featurestore fraud-features -n fraud-detection-ml \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.status} - {.message}{"\n"}{end}'
```

Le FeatureStore est pret quand le status est `Ready` et le pod Feast affiche `3/3 Running`.

### 4. Nettoyage

```bash
./openshift/cleanup.sh
```

## Utilisation du notebook

### Depuis un Workbench RHOAI

1. Dans le dashboard OpenShift AI, allez dans **Projects** > `fraud-detection-ml`
2. Creez un **Workbench** avec l'image Jupyter
3. Configurez les variables d'environnement suivantes dans le workbench :

   | Variable | Description |
   |----------|-------------|
   | `POSTGRES_HOST` | `postgres.fraud-detection-ml.svc.cluster.local` |
   | `POSTGRES_PORT` | `5432` |
   | `POSTGRES_DB` | `feast_db` |
   | `POSTGRES_USER` | `feast_user` |
   | `POSTGRES_PASSWORD` | Votre mot de passe PostgreSQL |
   | `AWS_ACCESS_KEY_ID` | Votre identifiant MinIO |
   | `AWS_SECRET_ACCESS_KEY` | Votre mot de passe MinIO |
   | `AWS_ENDPOINT_URL` | `http://minio.fraud-detection-ml.svc.cluster.local:9000` |
   | `AWS_DEFAULT_REGION` | `us-east-1` |

4. Uploadez le dossier `feature_repo/` et le notebook dans le workbench
5. Executez le notebook cellule par cellule

### Contenu du notebook

Le notebook `fraud_detection_feature_store_demo.ipynb` demontre le workflow complet :

| Etape | Description |
|-------|-------------|
| **1. Installation** | Installation de `feast[postgres]`, `scikit-learn` |
| **2. Configuration** | Generation du `feature_store.yaml` depuis les variables d'environnement |
| **3. Donnees** | Generation de 500 profils clients et statistiques de transactions |
| **4. Definitions** | Affichage des definitions de features (`features.py`) |
| **5. feast apply** | Enregistrement des features dans le registry S3 |
| **6. Materialisation** | Chargement des features dans PostgreSQL (online store) |
| **7. Training** | Recuperation des features historiques via `get_historical_features()` |
| **8. Modele** | Entrainement d'un RandomForest + evaluation |
| **9. Inference** | Prediction en temps reel via `get_online_features()` depuis PostgreSQL |
| **10. Architecture** | Schema recapitulatif |

## Features definies

### Entity

- **customer_id** : identifiant unique du client

### Feature Views

**customer_profile** (TTL: 365 jours)

| Feature | Type | Description |
|---------|------|-------------|
| `age` | INT64 | Age du client |
| `country` | STRING | Pays du client |
| `account_age_days` | INT64 | Anciennete du compte en jours |
| `credit_limit` | FLOAT64 | Limite de credit |
| `num_cards` | INT64 | Nombre de cartes bancaires |

**transaction_stats** (TTL: 30 jours)

| Feature | Type | Description |
|---------|------|-------------|
| `avg_transaction_amount_30d` | FLOAT64 | Montant moyen des transactions sur 30 jours |
| `num_transactions_7d` | INT64 | Nombre de transactions sur 7 jours |
| `num_transactions_1d` | INT64 | Nombre de transactions sur 1 jour |
| `max_transaction_amount_7d` | FLOAT64 | Montant max sur 7 jours |
| `num_foreign_transactions_30d` | INT64 | Transactions a l'etranger sur 30 jours |
| `num_declined_transactions_7d` | INT64 | Transactions refusees sur 7 jours |

### On-Demand Feature View

**fraud_risk_features** (calcule en temps reel a chaque requete)

| Feature | Type | Description |
|---------|------|-------------|
| `amount_ratio_to_avg` | FLOAT64 | Ratio montant / moyenne 30j |
| `amount_ratio_to_max` | FLOAT64 | Ratio montant / max 7j |
| `risk_score` | FLOAT64 | Score de risque composite |

## Points cles de la configuration

### Format du secret PostgreSQL pour Feast

Le Feast Operator attend un secret avec une **cle unique** nommee d'apres le type de store (ici `postgres`), contenant la configuration au format YAML :

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-creds
stringData:
  postgres: |
    host: postgres.fraud-detection-ml.svc.cluster.local
    port: 5432
    user: feast_user
    password: mon_mot_de_passe
    database: feast_db
```

> **Attention** : un secret avec des cles separees (`host`, `port`, `user`, `password`) ne fonctionnera pas.

### Credentials S3/MinIO

Les pods Feast ont besoin des variables d'environnement AWS pour acceder au registry S3 sur MinIO. Elles sont injectees via `envFrom` dans le FeatureStore CR sur les **trois containers** (registry, online, ui) :

```yaml
services:
  registry:
    local:
      server:
        envFrom:
          - secretRef:
              name: minio-creds
  onlineStore:
    server:
      envFrom:
        - secretRef:
            name: minio-creds
  ui:
    envFrom:
      - secretRef:
          name: minio-creds
```

### StorageClass

Les PVC utilisent `gp3-csi` (AWS EBS). Pour un autre provider, modifiez le champ `storageClassName` dans les fichiers `01-postgres.yaml` et `02-minio.yaml`.

## Troubleshooting

### Le FeatureStore reste en Failed

```bash
# Verifier le message d'erreur
oc get featurestore fraud-features -n fraud-detection-ml \
  -o jsonpath='{.status.conditions[?(@.type=="FeatureStore")].message}'
```

**Erreur** : `secret key postgres doesn't exist in secret postgres-creds`
- Le secret `postgres-creds` doit contenir une cle unique `postgres` (pas des cles separees)

### Le pod Feast est en CrashLoopBackOff

```bash
# Verifier les logs
oc logs -l feast.dev/name=fraud-features -n fraud-detection-ml --all-containers --tail=30
```

**Erreur** : `NoCredentialsError: Unable to locate credentials`
- Les variables AWS ne sont pas injectees. Verifiez que `envFrom` est configure sur les 3 containers dans le FeatureStore CR.

**Erreur** : `S3RegistryBucketNotExist: S3 bucket feast-registry does not exist`
- Le bucket n'a pas ete cree dans MinIO. Relancez le Job : `oc delete job minio-create-bucket -n fraud-detection-ml && oc apply -f openshift/04-minio-bucket-job.yaml`

### Le dashboard RHOAI ne montre pas le Feature Store

- Verifiez le label sur le FeatureStore CR : `oc get featurestore fraud-features -n fraud-detection-ml -o jsonpath='{.metadata.labels}'`
- Le label `feature-store-ui: enabled` doit etre present.
- Verifiez le label sur le namespace : `opendatahub.io/dashboard: "true"`

## References

- [Red Hat OpenShift AI 3.2 - Working with machine learning features](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.2/html/working_with_machine_learning_features/)
- [Feast documentation](https://docs.feast.dev/)
- [Feast Operator samples](https://github.com/feast-dev/feast/tree/stable/infra/feast-operator)
- [Feast Credit Score Tutorial](https://github.com/feast-dev/feast-credit-score-local-tutorial)
