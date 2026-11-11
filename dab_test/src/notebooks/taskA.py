# Databricks notebook source
import json

target_date = dbutils.widgets.get("target_date")

print(f"target_date = {target_date}")

store_list = [
    "SmartMart_001",
    "SmartMart_002",
    "SmartMart_003"
]

dbutils.jobs.taskValues.set(
    key="store_list",
    value=json.dumps(store_list)
)

dbutils.jobs.taskValues.set(
    key="target_date",
    value=target_date
)

result = {
    "status": "SUCCESS",
    "target_date": target_date,
    "store_count": len(store_list)
}

dbutils.notebook.exit(json.dumps(result))