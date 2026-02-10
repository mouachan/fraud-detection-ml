import os
from datetime import timedelta

import pandas as pd
from feast import Entity, FeatureView, Field, RequestSource
from feast.infra.offline_stores.contrib.postgres_offline_store.postgres_source import (
    PostgreSQLSource,
)
from feast.on_demand_feature_view import on_demand_feature_view
from feast.types import Float64, Int64, String

# ============================================================
# Entities
# ============================================================

customer = Entity(
    name="customer_id",
    join_keys=["customer_id"],
    description="Identifiant unique du client",
)

# ============================================================
# Data Sources (PostgreSQL)
# ============================================================

PG_CONN = (
    f"host={os.getenv('POSTGRES_HOST', 'postgres.fraud-detection-ml.svc.cluster.local')} "
    f"port={os.getenv('POSTGRES_PORT', '5432')} "
    f"dbname={os.getenv('POSTGRES_DB', 'feast_db')} "
    f"user={os.getenv('POSTGRES_USER', 'feast_user')} "
    f"password={os.getenv('POSTGRES_PASSWORD', '')}"
)

customer_profile_source = PostgreSQLSource(
    name="customer_profiles",
    query="SELECT * FROM customer_profiles",
    timestamp_field="event_timestamp",
    created_timestamp_column="created_timestamp",
)

transaction_stats_source = PostgreSQLSource(
    name="transaction_stats",
    query="SELECT * FROM transaction_stats",
    timestamp_field="event_timestamp",
    created_timestamp_column="created_timestamp",
)

# ============================================================
# Feature Views
# ============================================================

customer_profile = FeatureView(
    name="customer_profile",
    entities=[customer],
    ttl=timedelta(days=365),
    schema=[
        Field(name="age", dtype=Int64),
        Field(name="country", dtype=String),
        Field(name="account_age_days", dtype=Int64),
        Field(name="credit_limit", dtype=Float64),
        Field(name="num_cards", dtype=Int64),
    ],
    source=customer_profile_source,
)

transaction_stats = FeatureView(
    name="transaction_stats",
    entities=[customer],
    ttl=timedelta(days=30),
    schema=[
        Field(name="avg_transaction_amount_30d", dtype=Float64),
        Field(name="num_transactions_7d", dtype=Int64),
        Field(name="num_transactions_1d", dtype=Int64),
        Field(name="max_transaction_amount_7d", dtype=Float64),
        Field(name="num_foreign_transactions_30d", dtype=Int64),
        Field(name="num_declined_transactions_7d", dtype=Int64),
    ],
    source=transaction_stats_source,
)

# ============================================================
# On-Demand Feature View (computed at request time)
# ============================================================

transaction_request = RequestSource(
    name="transaction_request",
    schema=[
        Field(name="transaction_amount", dtype=Float64),
        Field(name="is_foreign_transaction", dtype=Int64),
    ],
)


@on_demand_feature_view(
    sources=[transaction_stats, transaction_request],
    schema=[
        Field(name="amount_ratio_to_avg", dtype=Float64),
        Field(name="amount_ratio_to_max", dtype=Float64),
        Field(name="risk_score", dtype=Float64),
    ],
    mode="pandas",
)
def fraud_risk_features(features_df: pd.DataFrame) -> pd.DataFrame:
    df = pd.DataFrame()
    avg = features_df["avg_transaction_amount_30d"].replace(0, 1)
    max_amt = features_df["max_transaction_amount_7d"].replace(0, 1)

    df["amount_ratio_to_avg"] = features_df["transaction_amount"] / avg
    df["amount_ratio_to_max"] = features_df["transaction_amount"] / max_amt

    df["risk_score"] = (
        df["amount_ratio_to_avg"] * 0.4
        + features_df["is_foreign_transaction"] * 0.3
        + (features_df["num_declined_transactions_7d"] / 10.0) * 0.3
    )
    return df
