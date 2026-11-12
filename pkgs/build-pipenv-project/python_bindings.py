# SPDX-License-Identifier: MIT
"""Generate native Pipenv input bindings from Nix-selected Python wheelhouses."""
import argparse
import json
from pathlib import Path
import sys


def write(views, old_roots, destination, python=None):
    from python_repository import interpreter_tags, selections
    selected = selections(views, interpreter_tags(python) if python is not None else None)
    destination.mkdir(parents=True, exist_ok=True)
    overrides = destination / 'requirements.txt'
    overrides.write_text(''.join(name + ' @ ' + module['wheel'].as_uri() + '\n'
                                 for name, module in sorted(selected.items())))
    configuration = {
        'modules': {name: {'version': module['version'], 'wheel': str(module['wheel'])}
                    for name, module in selected.items()},
        'oldRepositories': list(dict.fromkeys([*old_roots, *(str(view['repository']) for view in views)])),
        'overrides': str(overrides),
    }
    filename = destination / 'inputs.json'
    filename.write_text(json.dumps(configuration, sort_keys=True) + '\n')
    return filename


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--views', type=Path, required=True)
    parser.add_argument('--old-repositories', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--tools', required=True)
    args = parser.parse_args()
    sys.path.insert(0, args.tools)
    write(json.loads(args.views.read_text()), json.loads(args.old_repositories.read_text()), args.destination)


if __name__ == '__main__':
    main()
