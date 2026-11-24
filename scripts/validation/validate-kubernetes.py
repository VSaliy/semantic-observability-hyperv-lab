#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

FORBIDDEN_PROFILE_KEYS = {"SPRING_PROFILES" + "_ACTIVE", "spring.profiles.active"}
FORBIDDEN_FLAG_KEYS = {"QUERY_API_" + "ALLOW_DEV_AUTH", "query.allow-dev-auth"}


def _contains_dev_profile(value: object) -> bool:
  if not isinstance(value, str):
    return False
  tokens = [part.strip() for part in value.replace(";", ",").split(",")]
  return "dev" in tokens


def _check_node(node: Any, path: Path) -> None:
  if isinstance(node, dict):
    name = node.get("name")
    val = node.get("value")
    if name in FORBIDDEN_PROFILE_KEYS and _contains_dev_profile(val):
      raise ValueError(f"{path}: dev profile must not be enabled in Kubernetes manifests")
    if name in FORBIDDEN_FLAG_KEYS and str(val).strip().lower() in {"true", "1", "yes"}:
      raise ValueError(f"{path}: dev auth flag must not be enabled in Kubernetes manifests")
    for key, item in node.items():
      if key in FORBIDDEN_PROFILE_KEYS and _contains_dev_profile(item):
        raise ValueError(f"{path}: dev profile must not be enabled in Kubernetes manifests")
      if key in FORBIDDEN_FLAG_KEYS and str(item).strip().lower() in {"true", "1", "yes"}:
        raise ValueError(f"{path}: dev auth flag must not be enabled in Kubernetes manifests")
      _check_node(item, path)
  elif isinstance(node, list):
    for item in node:
      _check_node(item, path)


def validate_manifests(root: Path = Path("kubernetes")) -> None:
  for path in root.rglob("*.y*ml"):
    if path.is_file():
      docs = list(yaml.safe_load_all(path.read_text(encoding="utf-8")))
      for doc in docs:
        _check_node(doc, path)


if __name__ == "__main__":
  validate_manifests()
  print("validated kubernetes yaml")
