FROM registry.redhat.io/rhoai/odh-workbench-jupyter-datascience-cpu-py312-rhel9@sha256:f250503a7fb51d17840e0d4c8e0b1b248563c16aae4dbfc5b0fe7551d7271bc1

LABEL name="fraud-detection-datascience-workbench" \
      summary="Data Science workbench with Feast, Model Registry, and ONNX support" \
      description="Custom RHOAI Data Science workbench image with pre-installed packages for fraud detection ML lifecycle" \
      io.k8s.display-name="Fraud Detection Data Science Workbench" \
      io.openshift.build.source-location="https://github.com/mouachan/fraud-detection-ml"

USER 1001

RUN pip install --no-cache-dir \
    "feast[postgres]" \
    s3fs \
    skl2onnx \
    onnxruntime \
    model-registry \
    boto3 \
    mlflow

# MLflow plugin: auto-inject X-Mlflow-Workspace header for RHOAI multi-tenant MLflow
COPY --chown=1001:0 mlflow_rhoai_plugin/ /tmp/mlflow_rhoai_plugin/
RUN pip install --no-cache-dir /tmp/mlflow_rhoai_plugin/ && rm -rf /tmp/mlflow_rhoai_plugin/

# TLS: trust the cluster CA bundle (injected via trusted-ca-bundle ConfigMap mounted at /etc/pki/ca-trust/extracted/pem)
# REQUESTS_CA_BUNDLE is used by Python requests/urllib3/mlflow/boto3
ENV REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt

WORKDIR /opt/app-root/src
