# SPDX-License-Identifier: MIT
"""Rebind a temporary native Pipfile.lock to current Nix input wheels."""
import json
from pathlib import Path
import sys

configuration, native = map(Path, sys.argv[1:])
modules = json.loads(configuration.read_text())['modules']
data = json.loads(native.read_text())
for category, packages in data.items():
    if category == '_meta':
        continue
    for name, entry in packages.items():
        module = modules.get(name)
        if module:
            for key in ('git', 'ref', 'file', 'subdirectory', 'hashes', 'path', 'editable', 'version', 'index'):
                entry.pop(key, None)
            entry.update(path=module['wheel'], editable=False)
native.write_text(json.dumps(data, sort_keys=True, indent=4) + '\n')
