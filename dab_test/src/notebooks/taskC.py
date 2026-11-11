# Databricks notebook source
from datetime import datetime
import json

dbutils.widgets.text("param1", "")
param1 = dbutils.widgets.get("param1")

try:
    datetime.strptime(param1, "%Y-%m-%d")
except Exception as e:
    raise ValueError(f"param1 is not a valid date (YYYY-MM-DD): {param1}") from e

dbutils.notebook.exit(
    json.dumps({
        "status": "SUCCESS",
        "received_param": param1
    })
)