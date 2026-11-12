# SPDX-License-Identifier: MIT
"""Scope native Pipenv wheels to the dependency graph of the requested package."""
import argparse
from email import policy
from email.parser import BytesParser
from importlib.metadata import PathDistribution
import json
from pathlib import Path
import zipfile

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name, parse_wheel_filename
from packaging.version import Version

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--environment', type=Path, required=True)
parser.add_argument('--repositories', type=Path, required=True)
parser.add_argument('--roots', type=Path, required=True)
parser.add_argument('--destination', type=Path, required=True)
parser.add_argument('--runtime', type=Path, required=True)
args = parser.parse_args()
installed = {}
for path in args.environment.glob('lib/python*/site-packages/*.dist-info'):
    distribution = PathDistribution(path)
    installed[canonicalize_name(distribution.metadata['Name'])] = Version(distribution.version)
owned, candidates = {}, {}
for directory in json.loads(args.repositories.read_text()):
    for path in sorted(Path(directory).glob('*.whl')):
        name, version, _, _ = parse_wheel_filename(path.name)
        if installed.get(name) == version:
            previous = owned.setdefault(name, path)
            if previous.read_bytes() != path.read_bytes():
                raise ValueError('conflicting native project wheel: ' + name)
for path in sorted((args.environment / 'nix-support/wheels').glob('*.whl')):
    name, version, _, _ = parse_wheel_filename(path.name)
    if installed.get(name) == version:
        candidates[name] = path
candidates.update(owned)
args.destination.mkdir(parents=True, exist_ok=True)
args.runtime.mkdir(parents=True, exist_ok=True)
roots = json.loads(args.roots.read_text())
pending = ([name for name in installed if name in candidates or name not in {'pip', 'setuptools', 'wheel'}]
           if roots is None else [canonicalize_name(Requirement(root).name) for root in roots])
visited = set()
while pending:
    name = pending.pop()
    if name in visited:
        continue
    visited.add(name)
    if name not in candidates:
        raise ValueError('missing native runtime wheel: ' + name)
    path = candidates[name]
    directory = args.destination if name in owned else args.runtime
    (directory / path.name).write_bytes(path.read_bytes())
    with zipfile.ZipFile(path) as archive:
        metadata, = [entry for entry in archive.namelist() if entry.endswith('.dist-info/METADATA')]
        model = BytesParser(policy=policy.default).parsebytes(archive.read(metadata))
    # The native environment selects versions and platform branches. Extras
    # present in that environment are exportable too; unrelated test/build
    # tools have no path from the published wheel and never enter this view.
    pending.extend(canonicalize_name(Requirement(requirement).name)
                   for requirement in model.get_all('Requires-Dist', [])
                   if canonicalize_name(Requirement(requirement).name) in installed)
