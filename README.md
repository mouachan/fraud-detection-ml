# Fraud Detection with Feature Store & MLflow on OpenShift AI 3.3

A demonstration of **Feature Store** (Feast), **MLflow Experiment Tracking**, and **Model Registry** on **Red Hat OpenShift AI 3.3** for real-time bank fraud detection.

## Architecture

```
                         OpenShift AI 3.3
    +-----------------------------------------------------------+
    |                                                           |
    |   +-------------+        +-------------------------+      |
    |   |  Workbench   |        |  Feature Store (Feast)  |      |
    |   |  (Notebook)  |------->|  Online + Offline Store |      |
    |   +------+------+        +-------------------------+      |
    |          |                                                |
    |          v                                                |
    |   +------+------+                                         |
    |   |   MLflow      |   Experiment Tracking                 |
    |   |  (Dev Preview)|   Params, Metrics, Artifacts          |
    |   +------+------+                                         |
    |          |                                                |
    |          v                                                |
    |   +------+------+        +----------------+               |
    |   | MLflow Model |       | RHOAI Model    |               |
    |   | Registry     |------>| Registry       |               |
    |   +------+------+        +-------+--------+               |
    |          |                       |                         |
    |          v                       v                         |
    |   +-------------+        +----------------+               |
    |   |  S3 (MinIO)  |        | Model Serving  |               |
    |   |  Artifacts   |        | (KServe/OVMS)  |               |
    |   +-------------+        +----------------+               |
    +-----------------------------------------------------------+
```

### Components

| Component | Technology | Purpose |
|-----------|------------|---------|
| **Offline Store** | Parquet on S3 (MinIO) | Historical feature storage for training |
| **Online Store** | PostgreSQL 15 | Low-latency feature serving for inference |
| **Registry** | S3 / MinIO | Feature metadata catalog (`registry.db`) |
| **Feature Server** | Feast (RHOAI Operator) | gRPC and REST API to serve features |
| **UI** | Feast UI (RHOAI) | Web interface to browse features |
| **MLflow** | MLflow 3.6 (Dev Preview) | Experiment tracking, model registry |
| **Model Registry** | Kubeflow Model Registry | Model versioning and deployment |
| **Workbench** | Jupyter Notebook | Experimentation and model training |

### Why Parquet instead of PostgreSQL for the Offline Store?

The PostgreSQL offline store in Feast is a **contrib** module (not fully supported):

> *"The PostgreSQL offline store does not achieve full test coverage. Please do not assume complete stability."* -- [Feast docs](https://docs.feast.dev/reference/offline-stores/postgres)

Additionally, `PostgreSQLSource` is serialized as `CUSTOM_SOURCE` in the Feast protobuf, which causes the RHOAI dashboard Feature Views page to crash (`TypeError: Cannot read properties of undefined (reading 'uri')`). The dashboard expects `fileOptions.uri` which only exists on first-class data source types.

Using `FileSource` (Parquet on S3) is **fully supported**, uses the `BATCH_FILE` source type with `fileOptions.uri` properly populated, and works correctly with the RHOAI dashboard.

## Prerequisites

- OpenShift 4.14+ cluster
- Red Hat OpenShift AI 3.3 installed
- Feast Operator and MLflow Operator enabled in the DataScienceCluster:
  ```yaml
  spec:
    components:
      feastoperator:
        managementState: Managed
      mlflowoperator:
        managementState: Managed
      modelregistry:
        managementState: Managed
  ```
- `oc` CLI connected to the cluster
- StorageClass `gp3-csi` available (update the YAMLs if different)

## Project Structure

```
fraud-detection-ml/
+-- README.md
+-- .gitignore
+-- openshift/                             # Deployment manifests
|   +-- 00-namespace.yaml                  # Namespace with RHOAI label
|   +-- 01-secrets.yaml                    # Secrets (must be customized)
|   +-- 02-rbac.yaml                       # ServiceAccount, Roles, RoleBindings
|   +-- 03-minio.yaml                      # MinIO: PVC + Deployment + Service
|   +-- 04-minio-bucket-job.yaml           # Job to create the S3 bucket
|   +-- 05-postgres.yaml                   # PostgreSQL: PVC + Deployment + Service
|   +-- 06-init-data-job.yaml              # Job to load demo data into PostgreSQL
|   +-- 07-featurestore.yaml               # FeatureStore CR (Feast)
|   +-- 08-parquet-data-job.yaml           # Job to upload Parquet data to MinIO
|   +-- deploy.sh                          # Automated deployment script (10 steps)
|   +-- feast-init.sh                      # s3fs workaround + feast apply + materialize
|   +-- cleanup.sh                         # Cleanup script
+-- helm/fraud-detection-feast/            # Helm chart (alternative deployment)
|   +-- Chart.yaml
|   +-- values.yaml
|   +-- templates/
+-- feature_repo/                          # Feast definitions
|   +-- features.py                        # Entities, FeatureViews, On-Demand features
|   +-- permissions.py                     # Feast RBAC permissions
+-- notebooks/
    +-- fraud_detection_feature_store_demo.ipynb  # Feast + Model Serving pipeline
    +-- fraud_detection_mlflow_pipeline.ipynb     # MLflow experiment tracking pipeline
```

## Deployment

### 1. Configure secrets

Before deploying, edit `openshift/01-secrets.yaml` and replace the `<CHANGEZ_MOI>` placeholder values with your own credentials:

- `postgres-admin`: PostgreSQL password for the deployment
- `postgres-creds`: PostgreSQL connection for Feast (password must match `postgres-admin`)
- `minio-admin`: MinIO credentials for the deployment
- `minio-creds`: S3 credentials for Feast pods (must match `minio-admin`)
- `minio-data-connection`: Data Connection for the workbench (must match `minio-admin`)

### 2. Deploy

```bash
./openshift/deploy.sh
```

The script deploys in order:
1. Namespace `fraud-detection-ml` with label `opendatahub.io/dashboard: "true"`
2. Connection secrets
3. RBAC (ServiceAccount, Roles, and RoleBindings for Feast and dashboard)
4. MinIO (S3 registry + offline data) with persistent volume
5. Job to create the `feast-registry` bucket in MinIO
6. PostgreSQL (online store) with persistent volume
7. Job to load demo data into PostgreSQL (for the online store)
8. FeatureStore CR that triggers the Feast Operator
9. Job to upload demo data as Parquet files to MinIO (`s3://feast-registry/data/`)
10. s3fs workaround + `feast apply` + `feast materialize-incremental` (see [s3fs workaround](#s3fs-workaround) below)

### Deployment with Helm

As an alternative to the manual deployment, you can use the provided Helm chart:

```bash
# Deploy with default values
helm install fraud-feast helm/fraud-detection-feast/

# Deploy with custom values
helm install fraud-feast helm/fraud-detection-feast/ \
  --set postgres.password=mypassword \
  --set minio.rootUser=myadmin \
  --set minio.rootPassword=mysecret \
  --set storageClassName=gp3-csi

# Or with a values file
helm install fraud-feast helm/fraud-detection-feast/ -f my-values.yaml
```

Configurable parameters (`values.yaml`):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `namespace` | `fraud-detection-ml` | OpenShift namespace |
| `storageClassName` | `gp3-csi` | StorageClass for PVCs |
| `postgres.password` | `changeme` | PostgreSQL password |
| `postgres.database` | `feast_db` | Database name |
| `postgres.user` | `feast_user` | PostgreSQL user |
| `postgres.storageSize` | `10Gi` | PostgreSQL PVC size |
| `minio.rootUser` | `minio` | MinIO admin user |
| `minio.rootPassword` | `minio123` | MinIO admin password |
| `minio.storageSize` | `10Gi` | MinIO PVC size |
| `minio.bucketName` | `feast-registry` | S3 bucket name |
| `featureStore.gitUrl` | `https://github.com/mouachan/fraud-detection-ml` | Git repo URL |
| `featureStore.gitRef` | `main` | Git branch |
| `featureStore.subPath` | `feature_repo` | Sub-directory in the repo |
| `mlflow.trackingUri` | `https://mlflow.redhat-ods-applications.svc.cluster.local:8443` | MLflow tracking server URI |
| `feastInit.enabled` | `false` | Enable s3fs workaround Job (see note below) |

After `helm install` completes, run the s3fs workaround script manually:

```bash
./openshift/feast-init.sh
```

To uninstall:

```bash
helm uninstall fraud-feast
oc delete namespace fraud-detection-ml
```

### 3. s3fs workaround

The RHOAI 3.2 Feast image (`odh-feature-server-rhel9`) does not include the `s3fs` Python package, which causes `feast materialize-incremental` to fail when using Parquet files on S3/MinIO. The workaround installs `s3fs` into `/tmp/pip` inside the Feast pod and sets `PYTHONPATH` accordingly.

When using `deploy.sh`, this is handled automatically in step 10. When using Helm, run the script after `helm install`:

```bash
./openshift/feast-init.sh
```

The script:
1. Waits for the Feast pod to be ready
2. Installs `s3fs` in `/tmp/pip` (workaround for the missing package)
3. Runs `feast apply` to register feature definitions and RBAC permissions
4. Runs `feast materialize-incremental` to load features into the PostgreSQL online store

You can also pass a custom namespace:

```bash
./openshift/feast-init.sh my-namespace
```

### 4. Verification

```bash
# Check FeatureStore status
oc get featurestore -n fraud-detection-ml

# Check pods (expect 3/3 Running for the Feast pod)
oc get pods -n fraud-detection-ml

# Check all conditions
oc get featurestore fraud-features -n fraud-detection-ml \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.status} - {.message}{"\n"}{end}'

# Verify the client ConfigMap was generated
oc get configmap -l feast.dev/service-type=client -n fraud-detection-ml

# Verify permissions are registered
oc exec deployments/feast-fraud-features -c online -n fraud-detection-ml -- \
  python3 -c "from feast import FeatureStore; fs = FeatureStore(repo_path='/feast-data/fraud_detection/feature_repo'); print('Permissions:', [p.name for p in fs.list_permissions()])"
```

The FeatureStore is ready when:
- All conditions show `True`
- The Feast pod shows `3/3 Running`
- Permissions list returns `feast_user_permission` and `feast_admin_permission`

### 5. Cleanup

```bash
./openshift/cleanup.sh
```

## Feature Store RBAC

The RHOAI dashboard **requires** proper RBAC configuration to discover and display the Feature Store. Without it, the dashboard shows "No feature store repositories available". The configuration consists of **three parts** that must all be in place:

### 1. Kubernetes Roles (defined in `02-rbac.yaml`)

| Role | Scope | Bound To |
|------|-------|----------|
| `feast-writer` | Full CRUD on FeatureStore resources | Dashboard service account (`rhods-dashboard`) |
| `feast-reader` | Read-only on FeatureStore resources | All authenticated users (`system:authenticated`) |

```yaml
# feast-writer: bound to the RHOAI dashboard service account
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: feast-writer
rules:
  - apiGroups: ["feast.dev"]
    resources: ["featurestores"]
    verbs: ["get", "list", "watch", "create", "update", "delete"]
  - apiGroups: [""]
    resources: ["configmaps", "secrets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: feast-writer-dashboard
subjects:
  - kind: ServiceAccount
    name: rhods-dashboard
    namespace: redhat-ods-applications
roleRef:
  kind: Role
  name: feast-writer
  apiGroup: rbac.authorization.k8s.io
```

```yaml
# feast-reader: bound to all authenticated users
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: feast-reader
rules:
  - apiGroups: ["feast.dev"]
    resources: ["featurestores"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: feast-reader-authenticated
subjects:
  - kind: Group
    name: system:authenticated
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: feast-reader
  apiGroup: rbac.authorization.k8s.io
```

### 2. Feast Permissions (defined in `feature_repo/permissions.py`)

This file maps Kubernetes roles to Feast-level actions. **It must be present in the feature repo and registered via `feast apply`.**

| Permission | Role | Actions |
|------------|------|---------|
| `feast_user_permission` | `feast-reader` | DESCRIBE, READ_ONLINE, READ_OFFLINE |
| `feast_admin_permission` | `feast-writer` | All actions (CREATE, UPDATE, DELETE, READ, WRITE) |

```python
from feast.feast_object import ALL_RESOURCE_TYPES
from feast.permissions.action import READ, AuthzedAction, ALL_ACTIONS
from feast.permissions.permission import Permission
from feast.permissions.policy import RoleBasedPolicy

admin_roles = ["feast-writer"]
user_roles = ["feast-reader"]

feast_user_permission = Permission(
    name="feast_user_permission",
    types=ALL_RESOURCE_TYPES,
    policy=RoleBasedPolicy(roles=user_roles),
    actions=[AuthzedAction.DESCRIBE] + READ,
)

feast_admin_permission = Permission(
    name="feast_admin_permission",
    types=ALL_RESOURCE_TYPES,
    policy=RoleBasedPolicy(roles=admin_roles),
    actions=ALL_ACTIONS,
)
```

### 3. FeatureStore CR references the roles

The `authz` section in the FeatureStore CR (`07-featurestore.yaml`) must list the Kubernetes roles:

```yaml
spec:
  authz:
    kubernetes:
      roles:
        - feast-writer
        - feast-reader
```

> **Important**: All three parts are required. Missing any one of them (Kubernetes roles, `permissions.py`, or `authz` in the CR) will cause the dashboard to not display the Feature Store.

## FeatureStore CR

The FeatureStore CR (`07-featurestore.yaml`) configures the Feast deployment:

```yaml
apiVersion: feast.dev/v1alpha1
kind: FeatureStore
metadata:
  name: fraud-features
  namespace: fraud-detection-ml
  labels:
    feature-store-ui: enabled
spec:
  feastProject: fraud_detection
  feastProjectDir:
    git:
      url: https://github.com/mouachan/fraud-detection-ml
      ref: main
      subPath: feature_repo
  authz:
    kubernetes:
      roles:
        - feast-writer
        - feast-reader
  services:
    onlineStore:
      persistence:
        store:
          type: postgres
          secretRef:
            name: postgres-creds
      server:
        envFrom:
          - secretRef:
              name: minio-creds
    registry:
      local:
        server:
          restAPI: true
          envFrom:
            - secretRef:
                name: minio-creds
        persistence:
          file:
            path: s3://feast-registry/registry.db
    ui:
      envFrom:
        - secretRef:
            name: minio-creds
```

Key points:
- **No `offlineStore` section**: the default file-based (Dask) offline store is used, reading Parquet files from S3
- **`feastProjectDir.git`**: the operator clones `features.py` and `permissions.py` from this Git repo
- **`envFrom` on all containers**: MinIO/S3 credentials are injected into the registry, online store, and UI containers
- **`restAPI: true`**: enables the REST API on the registry for the dashboard

## TLS

TLS is **automatically provisioned** by the Feast Operator using OpenShift service-serving certificates. All Feast services (online store, registry, UI) listen on port 443 with TLS enabled. The operator creates:

- TLS secrets for each service (`feast-fraud-features-online-tls`, `feast-fraud-features-registry-tls`, `feast-fraud-features-ui-tls`)
- A client CA ConfigMap (`feast-fraud-features-client-ca`) with the service-serving CA certificate
- A client configuration ConfigMap (`feast-fraud-features-client`) with the `feature_store.yaml` pointing to HTTPS endpoints

Clients (workbenches, notebooks) must mount the CA certificate to connect to the Feast servers.

## MLflow (Developer Preview)

MLflow is deployed as a **Developer Preview** feature in RHOAI 3.3 via the `mlflowoperator` component.

### MLflow Server Deployment

Create an MLflow CR to deploy the server:

```yaml
apiVersion: mlflow.opendatahub.io/v1
kind: MLflow
metadata:
  name: mlflow
spec:
  serveArtifacts: true
  artifactsDestination: "s3://mlflow-artifacts/"
  envFrom:
    - secretRef:
        name: mlflow-s3-credentials
  env:
    - name: MLFLOW_S3_ENDPOINT_URL
      value: "http://minio.fraud-detection-ml.svc.cluster.local:9000"
  storage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 5Gi
```

The MLflow CR is **cluster-scoped** -- the deployment is created in `redhat-ods-applications`.

Create the S3 credentials secret in `redhat-ods-applications`:

```bash
oc create secret generic mlflow-s3-credentials -n redhat-ods-applications \
  --from-literal=AWS_ACCESS_KEY_ID=minioadmin \
  --from-literal=AWS_SECRET_ACCESS_KEY=<your-password> \
  --from-literal=AWS_DEFAULT_REGION=us-east-1
```

Create the `mlflow-artifacts` bucket in MinIO:

```bash
oc exec -n fraud-detection-ml deployment/minio -- \
  mc alias set local http://localhost:9000 minioadmin <your-password> && \
  mc mb local/mlflow-artifacts --ignore-existing
```

### MLflow Features

| Feature | Status |
|---------|--------|
| Experiment Tracking | Available (Dev Preview) |
| MLflow Model Registry | Available (Dev Preview) |
| Autologging (sklearn, etc.) | Available |
| Artifact Storage (S3/MinIO) | Available |
| Kubernetes Auth | Available |
| Workspace Isolation (K8s namespaces) | Available |

### MLflow Pipeline Notebook

The `fraud_detection_mlflow_pipeline.ipynb` notebook demonstrates the full MLflow lifecycle:

| Step | Description |
|------|-------------|
| **1. Configure** | Connect to MLflow server with K8s auth + TLS |
| **2. Train (manual)** | Log params, metrics, confusion matrix, ROC curve, feature importance |
| **3. Train (autolog)** | Compare RandomForest, GradientBoosting, LogisticRegression |
| **4. Register** | Register best model in MLflow Model Registry |
| **5. Promote** | Transition to Production stage, add tags and alias |
| **6. RHOAI Registry** | Export to ONNX, upload to S3, register in RHOAI Model Registry with full metadata |

## Using the Notebook

### From an RHOAI Workbench

1. In the OpenShift AI dashboard, go to **Projects** > `fraud-detection-ml`
2. Create a **Workbench** with the custom image (`Fraud Detection Data Science`)
3. When creating the workbench, select the `fraud-detection` **Feature Store** in the configuration (this auto-mounts the Feast client config and CA certificate)
4. Attach the **Data Connection** `minio-data-connection` (injects `AWS_*` env vars)
5. Mount the **ConfigMap** `mlflow-config` as **environment variables** (injects `MLFLOW_TRACKING_URI`, `MLFLOW_S3_ENDPOINT_URL`)
6. Mount the **ConfigMap** `trusted-ca-bundle` as a **volume** at `/etc/pki/ca-trust/extracted/pem` (cluster CA for TLS)
7. Upload the `feature_repo/` folder and the notebook to the workbench
8. Run the notebook cell by cell

### Notebooks

#### `fraud_detection_feature_store_demo.ipynb` - Feast + Model Serving

Full workflow from feature retrieval to model serving:

| Step | Description |
|------|-------------|
| **1-3.** | Connect to Feast Feature Store, explore features |
| **4-5.** | Retrieve historical features, train RandomForest |
| **6.** | Real-time prediction via online store (PostgreSQL) |
| **7-8.** | Export to ONNX, upload to MinIO |
| **9.** | Register in RHOAI Model Registry |
| **10-11.** | Deploy via KServe/OVMS, end-to-end inference |

#### `fraud_detection_mlflow_pipeline.ipynb` - MLflow Pipeline

Complete MLflow experiment tracking and model lifecycle:

| Step | Description |
|------|-------------|
| **1.** | Configure MLflow (K8s auth + TLS) |
| **2.** | Train with manual tracking (params, metrics, plots) |
| **3.** | Train with autolog (compare 3 models) |
| **4.** | Register best model in MLflow Registry |
| **5.** | Promote to Production (tags, alias) |
| **6.** | Register in RHOAI Model Registry (ONNX + full metadata) |

## Feature Definitions

### Entity

- **customer_id**: unique customer identifier

### Data Sources

Data sources are **Parquet files stored on MinIO (S3)**. The `FileSource` is a fully-supported Feast data source type (`BATCH_FILE`) that requires `s3_endpoint_override` to point to MinIO instead of AWS S3:

```python
customer_profile_source = FileSource(
    name="customer_profiles",
    path="s3://feast-registry/data/customer_profiles.parquet",
    s3_endpoint_override=S3_ENDPOINT,
    timestamp_field="event_timestamp",
    created_timestamp_column="created_timestamp",
)
```

### Feature Views

**customer_profile** (TTL: 365 days) - Source: `s3://feast-registry/data/customer_profiles.parquet`

| Feature | Type | Description |
|---------|------|-------------|
| `age` | INT64 | Customer age |
| `country` | STRING | Customer country code |
| `account_age_days` | INT64 | Account age in days |
| `credit_limit` | FLOAT64 | Credit limit |
| `num_cards` | INT64 | Number of bank cards |

**transaction_stats** (TTL: 30 days) - Source: `s3://feast-registry/data/transaction_stats.parquet`

| Feature | Type | Description |
|---------|------|-------------|
| `avg_transaction_amount_30d` | FLOAT64 | Average transaction amount over 30 days |
| `num_transactions_7d` | INT64 | Number of transactions over 7 days |
| `num_transactions_1d` | INT64 | Number of transactions over 1 day |
| `max_transaction_amount_7d` | FLOAT64 | Maximum transaction amount over 7 days |
| `num_foreign_transactions_30d` | INT64 | Foreign transactions over 30 days |
| `num_declined_transactions_7d` | INT64 | Declined transactions over 7 days |

### On-Demand Feature View

**fraud_risk_features** (computed in real-time at each request)

| Feature | Type | Description |
|---------|------|-------------|
| `amount_ratio_to_avg` | FLOAT64 | Transaction amount / 30-day average ratio |
| `amount_ratio_to_max` | FLOAT64 | Transaction amount / 7-day max ratio |
| `risk_score` | FLOAT64 | Composite risk score (weighted: amount ratio 40%, foreign transaction 30%, declined ratio 30%) |

## Configuration Details

### PostgreSQL Secret Format for Feast

The Feast Operator expects a secret with a **single key** named after the store type (`postgres`), containing YAML-formatted connection config:

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
    password: your_password
    database: feast_db
```

> **Warning**: A secret with separate keys (`host`, `port`, `user`, `password`) will not work. The Feast Operator requires a single `postgres` key with YAML content.

### S3/MinIO Credentials

Feast pods need AWS environment variables to access MinIO. The `minio-creds` secret must contain:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: minio-creds
stringData:
  AWS_ACCESS_KEY_ID: your_access_key
  AWS_SECRET_ACCESS_KEY: your_secret_key
  AWS_ENDPOINT_URL: http://minio.fraud-detection-ml.svc.cluster.local:9000
  AWS_DEFAULT_REGION: us-east-1
```

These variables are injected via `envFrom` in the FeatureStore CR on **all three containers** (registry, online, ui):

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

### Parquet Data Files

The demo data is generated and uploaded to MinIO as Parquet files by the `08-parquet-data-job.yaml` Job. String columns are explicitly cast to `pa.string()` (instead of `pa.large_string()`) for compatibility with Feast 0.58.0, which does not support the `large_string` Arrow type.

The files are stored at:
- `s3://feast-registry/data/customer_profiles.parquet` (50 rows)
- `s3://feast-registry/data/transaction_stats.parquet` (50 rows)

### StorageClass

The PVCs use `gp3-csi` (AWS EBS). For a different provider, update the `storageClassName` field in `05-postgres.yaml` and `03-minio.yaml`.

## Troubleshooting

### FeatureStore stays in Failed state

```bash
# Check the error message
oc get featurestore fraud-features -n fraud-detection-ml \
  -o jsonpath='{.status.conditions[?(@.type=="FeatureStore")].message}'
```

**Error**: `secret key postgres doesn't exist in secret postgres-creds`
- The `postgres-creds` secret must contain a single key `postgres` (not separate keys)

### Feast pod is in CrashLoopBackOff

```bash
# Check the logs
oc logs -l feast.dev/name=fraud-features -n fraud-detection-ml --all-containers --tail=30
```

**Error**: `NoCredentialsError: Unable to locate credentials`
- AWS variables are not injected. Verify that `envFrom` is configured on all 3 containers in the FeatureStore CR.

**Error**: `S3RegistryBucketNotExist: S3 bucket feast-registry does not exist`
- The bucket was not created in MinIO. Re-run the Job:
  ```bash
  oc delete job minio-create-bucket -n fraud-detection-ml
  oc apply -f openshift/04-minio-bucket-job.yaml
  ```

### RHOAI Dashboard does not show the Feature Store

The dashboard requires **all three RBAC components** to display the Feature Store:

1. Verify the `permissions.py` file is present in the feature repo and `feast apply` has been run:
   ```bash
   oc exec deployments/feast-fraud-features -c online -n fraud-detection-ml -- \
     python3 -c "from feast import FeatureStore; fs = FeatureStore(repo_path='/feast-data/fraud_detection/feature_repo'); print([p.name for p in fs.list_permissions()])"
   ```
   Expected: `['feast_user_permission', 'feast_admin_permission']`

2. Verify the Feast RBAC roles exist and are bound:
   ```bash
   oc get roles feast-writer feast-reader -n fraud-detection-ml
   oc get rolebinding feast-writer-dashboard feast-reader-authenticated -n fraud-detection-ml
   ```

3. Verify the FeatureStore CR has RBAC roles configured:
   ```bash
   oc get featurestore fraud-features -n fraud-detection-ml \
     -o jsonpath='{.spec.authz}'
   ```
   Expected: `{"kubernetes":{"roles":["feast-writer","feast-reader"]}}`

4. Verify the namespace label:
   ```bash
   oc get namespace fraud-detection-ml --show-labels | grep opendatahub
   ```
   Expected: `opendatahub.io/dashboard=true`

5. Check dashboard logs for errors:
   ```bash
   oc logs -l app=rhods-dashboard -n redhat-ods-applications --tail=100 | grep -i feature
   ```

### Feature Views page shows a TypeError

**Error**: `TypeError: Cannot read properties of undefined (reading 'uri')`

This happens when data sources use `PostgreSQLSource` (contrib), which is serialized as `CUSTOM_SOURCE` in the Feast protobuf. The dashboard expects `fileOptions.uri` which doesn't exist on custom sources.

**Fix**: Use `FileSource` (Parquet on S3) instead of `PostgreSQLSource`. See the [Why Parquet?](#why-parquet-instead-of-postgresql-for-the-offline-store) section.

### feast apply fails with `KeyError: 'large_string'`

Feast 0.58.0 doesn't support the `large_string` Arrow type. Ensure Parquet files are written with `pa.string()` columns. The `08-parquet-data-job.yaml` handles this automatically by casting `large_string` to `string` before writing.

## Custom Workbench Image

The custom workbench image (`quay.io/mouachan/fraud-detection-datascience-workbench:2025.2`) includes all required dependencies:

| Package | Purpose |
|---------|---------|
| `feast[postgres]` | Feature Store client |
| `mlflow` | Experiment tracking |
| `model-registry` | RHOAI Model Registry client |
| `skl2onnx` | ONNX export |
| `onnxruntime` | ONNX inference |
| `boto3` | S3/MinIO access |
| `s3fs` | S3 filesystem |

The image also sets `REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt` so that Python libraries (requests, urllib3, mlflow, boto3) automatically trust the cluster CA certificates injected by the `trusted-ca-bundle` ConfigMap.

To rebuild and push:

```bash
cd datascience-custom-image
podman build --platform linux/amd64 -t quay.io/mouachan/fraud-detection-datascience-workbench:2025.2 .
podman push quay.io/mouachan/fraud-detection-datascience-workbench:2025.2
```

Then re-import the ImageStream tag on the cluster:

```bash
oc import-image fraud-detection-datascience:2025.2 \
  --from=quay.io/mouachan/fraud-detection-datascience-workbench:2025.2 \
  -n redhat-ods-applications --confirm
```

### Workbench Environment Configuration

The notebook relies on environment variables injected by Kubernetes resources rather than hardcoded values. Attach these to the workbench:

| Resource | Type | Provides |
|----------|------|----------|
| `minio-data-connection` | Data Connection (Secret) | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_ENDPOINT`, `AWS_DEFAULT_REGION` |
| `mlflow-config` | ConfigMap (env vars) | `MLFLOW_TRACKING_URI`, `MLFLOW_S3_ENDPOINT_URL` |
| `trusted-ca-bundle` | ConfigMap (volume at `/etc/pki/ca-trust/extracted/pem`) | Cluster CA certificates for TLS |

The service account token (`/var/run/secrets/kubernetes.io/serviceaccount/token`) is auto-mounted by Kubernetes and used for MLflow and Model Registry authentication.

## References

- [Red Hat OpenShift AI 3.3 - Working with machine learning features](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/working_with_machine_learning_features/)
- [MLflow on OpenShift AI](https://ai-on-openshift.io/tools-and-applications/mlflow/mlflow/)
- [Feast documentation](https://docs.feast.dev/)
- [Feast Operator RBAC with TLS example](https://github.com/feast-dev/feast/tree/master/examples/operator-rbac-openshift-tls)
- [Feast Operator samples](https://github.com/feast-dev/feast/tree/stable/infra/feast-operator)
- [Feast PostgreSQL offline store limitations](https://docs.feast.dev/reference/offline-stores/postgres)
- [Feast FileSource documentation](https://docs.feast.dev/reference/data-sources/file)
