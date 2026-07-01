#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

import yaml

for path in Path("kubernetes").rglob("*.y*ml"):
  if path.is_file():
    list(yaml.safe_load_all(path.read_text(encoding="utf-8")))
print("validated kubernetes yaml")
