#!/usr/bin/env python3
from pathlib import Path
import yaml

path = Path('semantic-search/query-api/openapi/openapi.yaml')
yaml.safe_load(path.read_text(encoding='utf-8'))
print('validated openapi yaml')
