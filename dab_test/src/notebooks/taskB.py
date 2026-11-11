# Databricks notebook source
import json

item = dbutils.widgets.get("item")

print(f"processing store = {item}")

result = {
    "status": "SUCCESS",
    "store_id": item
}

dbutils.notebook.exit(json.dumps(result))