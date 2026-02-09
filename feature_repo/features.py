from datetime import timedelta

import pandas as pd
from feast import Entity, FeatureView, Field, RequestSource
from feast.data_format import ParquetFormat
from feast.infra.offline_stores.file_source import FileSource
from feast.on_demand_feature_view import on_demand_feature_view
from feast.types import Float64, Int64, String

# ============================================================
# Entities
# ============================================================

customer = Entity(
    name="customer_id",
    description="Identifiant unique du client",
)

# ============================================================
# Data Sources
# ============================================================

customer_profile_source = FileSource(
    name="customer_profiles",
    path="data/customer_profiles.parquet",
    file_format=ParquetFormat(),
    timestamp_field="event_timestamp",
    created_timestamp_column="created_timestamp",
)

transaction_stats_source = FileSource(
    name="transaction_stats",
    path="data/transaction_stats.parquet",
    file_format=ParquetFormat(),
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
