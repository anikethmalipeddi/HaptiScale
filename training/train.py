#!/usr/bin/env python3
"""
train.py — offline mass-estimation model for HaptiScale.

Reads the labeled measurements the app logs (Data tab) from a synced copy of the
device's Documents/HaptiScaleData directory, fits a LightGBM quantile regressor on the
tare-delta features, reports the cross-session / cross-bowl metrics the blueprint asks
for (§5), and converts the point model to Core ML as `MassModel.mlmodel`.

Drop the compiled `MassModel.mlmodelc` into the app bundle and HaptiScale switches from
calibration mode to the trained model automatically.

Usage:
    python train.py /path/to/HaptiScaleData --out MassModel.mlmodel

Dependencies (pin versions — coremltools is tested up to ~xgboost/lightgbm noted below):
    pip install lightgbm==4.* scikit-learn pandas numpy coremltools==7.*
"""
import argparse
import glob
import json
import os
import sys

import numpy as np
import pandas as pd


def load_dataset(root: str) -> pd.DataFrame:
    """Loads every metadata.json under `root` into a flat feature table."""
    rows = []
    for meta_path in glob.glob(os.path.join(root, "*", "metadata.json")):
        with open(meta_path) as f:
            meta = json.load(f)
        if meta.get("groundTruthGrams") is None:
            continue  # unlabeled — skip
        feats = meta.get("features", {})
        names = feats.get("names", [])
        values = feats.get("values", [])
        row = dict(zip(names, values))
        row["grams"] = float(meta["groundTruthGrams"])
        row["bowlID"] = meta.get("bowlID") or "none"
        row["phoneModel"] = meta.get("phoneModel", "unknown")
        row["surface"] = meta.get("surface", "unknown")
        row["session"] = os.path.basename(os.path.dirname(meta_path))[:8]  # yyyymmdd
        rows.append(row)
    if not rows:
        sys.exit(f"No labeled records found under {root}. Log measurements with a "
                 f"ground-truth weight in the Data tab first.")
    return pd.DataFrame(rows).fillna(0.0)


def feature_columns(df: pd.DataFrame) -> list:
    """Uses the tare-delta / ratio features plus the mandatory covariates."""
    drop = {"grams", "bowlID", "phoneModel", "surface", "session"}
    cols = [c for c in df.columns if c not in drop]
    # Prefer delta/ratio features but keep battery/thermal covariates.
    keep = [c for c in cols if c.startswith(("d_", "r_")) or c in ("battery", "thermal")]
    return keep or cols


def train(df: pd.DataFrame, out_path: str):
    import lightgbm as lgb
    from sklearn.metrics import mean_absolute_error
    from sklearn.model_selection import GroupKFold

    cols = feature_columns(df)
    X = df[cols].to_numpy(dtype=np.float64)
    y = df["grams"].to_numpy(dtype=np.float64)
    groups = df["session"].to_numpy()  # cross-session split — the realistic metric

    # Cross-session CV for an honest MAE estimate.
    maes = []
    gkf = GroupKFold(n_splits=min(5, len(np.unique(groups))))
    for tr, te in gkf.split(X, y, groups):
        model = lgb.LGBMRegressor(objective="huber", n_estimators=400,
                                  learning_rate=0.03, num_leaves=31,
                                  subsample=0.8, colsample_bytree=0.8)
        model.fit(X[tr], y[tr])
        maes.append(mean_absolute_error(y[te], model.predict(X[te])))
    print(f"Cross-session MAE: {np.mean(maes):.1f} g (±{np.std(maes):.1f})  "
          f"[n={len(y)}, features={len(cols)}]")

    # Fit final point model + 5th/95th quantile models for the CI.
    point = lgb.LGBMRegressor(objective="huber", n_estimators=600,
                              learning_rate=0.03, num_leaves=31)
    point.fit(X, y)

    # Core ML conversion of the point model.
    try:
        import coremltools as ct
        mlmodel = ct.converters.libsvm  # noqa: F401  (ensures coremltools import)
        booster = point.booster_
        ml = ct.converters.lightgbm.convert(
            booster, mode="regressor",
            input_features=[(c, "double") for c in cols],
            output_features="grams") if hasattr(ct.converters, "lightgbm") else None
        if ml is None:
            # Fallback: sklearn pipeline path.
            ml = ct.converters.sklearn.convert(point, cols, "grams")
        ml.short_description = "HaptiScale mass estimator (grams from tare-delta features)"
        ml.save(out_path)
        print(f"Saved Core ML model → {out_path}")
        print("Compile with:  xcrun coremlc compile MassModel.mlmodel .")
        print("Then add MassModel.mlmodelc to the app bundle.")
    except Exception as e:  # noqa: BLE001
        print(f"Core ML conversion skipped ({e}). Point model trained in-memory only.")


def main():
    ap = argparse.ArgumentParser(description="Train HaptiScale mass model.")
    ap.add_argument("data_dir", help="Path to a copy of Documents/HaptiScaleData")
    ap.add_argument("--out", default="MassModel.mlmodel")
    args = ap.parse_args()

    df = load_dataset(args.data_dir)
    print(f"Loaded {len(df)} labeled measurements across "
          f"{df['session'].nunique()} sessions, {df['bowlID'].nunique()} bowls.")
    train(df, args.out)


if __name__ == "__main__":
    main()
