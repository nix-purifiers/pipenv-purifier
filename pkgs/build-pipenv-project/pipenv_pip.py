# SPDX-License-Identifier: MIT
"""Run Pipenv native pip with Nix repository bindings and optional wheel capture."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

native_paths = sys.path.copy()
if os.environ.get('PIPENV_PURIFIER_SITE_PATH'):
    sys.path[:0] = [path for path in json.loads(os.environ['PIPENV_PURIFIER_SITE_PATH']) if path and any(part in ('site-packages','dist-packages') for part in Path(path).parts)]
import pipenv
import pipenv.patched.pip as pip
from pipenv.patched.pip._internal.cli import main_parser
from pipenv.patched.pip._internal.cli.main import main

# Keep the adapter when native pip delegates --python to a virtualenv.
# Build-isolation subprocesses retain pip's original entry point instead.
os.environ['PIPENV_PURIFIER_SITE_PATH'] = json.dumps([path for path in sys.path if path and any(part in ('site-packages','dist-packages') for part in Path(path).parts)])
main_parser.get_runnable_pip = lambda: str(Path(__file__).resolve())

bindings = os.environ.get('PIPENV_PURIFIER_BINDINGS')
if bindings:
    from pipenv.patched.pip._internal.models.link import Link
    from pipenv.patched.pip._internal.resolution.resolvelib.factory import Factory
    from pipenv.patched.pip._vendor.packaging.requirements import Requirement
    from pipenv.patched.pip._vendor.packaging.utils import canonicalize_name

    modules = json.loads(Path(bindings).read_text())['modules']
    original = Factory._make_requirements_from_install_req

    def requirements(self, requirement, requested_extras):
        module = modules.get(canonicalize_name(requirement.name)) if requirement.name else None
        if module and requirement.match_markers(requested_extras):
            wheel = Path(module['wheel'])
            extras = '[' + ','.join(sorted(requirement.extras)) + ']' if requirement.extras else ''
            requirement.req = Requirement(requirement.name + extras + ' @ ' + wheel.as_uri())
            requirement.link = requirement.original_link = Link(wheel.as_uri())
            requirement.local_file_path = str(wheel)
            with wheel.open('rb') as source:
                requirement.hash_options = {'sha256': [hashlib.file_digest(source, 'sha256').hexdigest()]}
        yield from original(self, requirement, requested_extras)

    Factory._make_requirements_from_install_req = requirements

    # Native conflict reporting and `pip check` must apply the same input
    # bindings as resolution, while installed project metadata stays native.
    from pipenv.patched.pip._internal.metadata.importlib._dists import Distribution
    from pipenv.patched.pip._vendor.packaging.specifiers import SpecifierSet
    original_dependencies = Distribution.iter_dependencies

    def dependencies(self, extras=()):
        for requirement in original_dependencies(self, extras):
            module = modules.get(canonicalize_name(requirement.name))
            if module:
                requirement = Requirement(str(requirement))
                requirement.specifier = SpecifierSet('==' + module['version'])
                requirement.url = None
            yield requirement

    Distribution.iter_dependencies = dependencies

capture = os.environ.get('PIPENV_PURIFIER_EXPORT_WHEELS')
if capture:
    from pipenv.patched.pip._internal.req import req_install
    original_install = req_install.install_wheel

    def install(name, wheel_path, *args, **kwargs):
        destination = Path(capture)
        destination.mkdir(parents=True, exist_ok=True)
        wheel = Path(wheel_path)
        with tempfile.NamedTemporaryFile(dir=destination, delete=False) as temporary:
            temporary_path = Path(temporary.name)
            with wheel.open('rb') as source:
                shutil.copyfileobj(source, temporary)
        try:
            try:
                os.link(temporary_path, destination / wheel.name)
            except FileExistsError:
                with wheel.open('rb') as source, (destination / wheel.name).open('rb') as previous:
                    if hashlib.file_digest(source, 'sha256').digest() != hashlib.file_digest(previous, 'sha256').digest():
                        raise ValueError('conflicting native wheel bytes: ' + wheel.name)
        finally:
            temporary_path.unlink()
        return original_install(name, wheel_path, *args, **kwargs)

    req_install.install_wheel = install

if __name__ == '__main__':
    # Bootstrap the vendored installer without letting its SDK metadata
    # mask packages already installed in the target virtual environment.
    sys.path[:] = native_paths
    sys.exit(main())
