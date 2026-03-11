"""MLflow RequestHeaderProvider for RHOAI workspace context.

RHOAI 3.3 MLflow (Developer Preview) requires an X-Mlflow-Workspace header
on every API call for multi-tenant namespace isolation.

This plugin reads the MLFLOW_RHOAI_WORKSPACE environment variable and injects
the header automatically via MLflow's request_header_provider entry point.

Note: We use MLFLOW_RHOAI_WORKSPACE (not MLFLOW_WORKSPACE) to avoid triggering
MLflow 3.x built-in workspace validation which probes /api/3.0/mlflow/server-info
- an endpoint not supported by the RHOAI MLflow server.
"""

import os

from mlflow.tracking.request_header.abstract_request_header_provider import (
    RequestHeaderProvider,
)


class RhoaiWorkspaceHeaderProvider(RequestHeaderProvider):
    def in_context(self):
        return "MLFLOW_RHOAI_WORKSPACE" in os.environ

    def request_headers(self):
        return {"X-Mlflow-Workspace": os.environ["MLFLOW_RHOAI_WORKSPACE"]}
