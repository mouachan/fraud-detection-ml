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
    boto3

USER 1001

WORKDIR /opt/app-root/src
