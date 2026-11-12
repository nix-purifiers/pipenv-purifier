# SPDX-License-Identifier: MIT
"""Run native Pipenv with scoped Nix dependency bindings."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import sys
import shutil
import subprocess
import tempfile


@contextmanager
def native_inputs():
    if os.environ.get('PIPENV_PURIFIER_INTERNAL') or os.environ.get('PIPENV_PURIFIER_MODE') == 'off':
        yield
        return
    root = Path(os.environ['PIPENV_PIPFILE']).resolve().parent if os.environ.get('PIPENV_PIPFILE') else Path.cwd()
    while not (root / 'Pipfile').exists() and root.parent != root:
        root = root.parent
    lockfile = Path(os.environ.get('PIPENV_PURIFIER_LOCKFILE', root / 'pipenv-purifier.lock.json'))
    if not lockfile.exists():
        print('pipenv-purifier: warning: no lockfile; Pipenv is resolving dependencies impurely', file=sys.stderr)
        yield
        return
    if not any(argument in ('run', 'shell', 'sync', 'install') for argument in sys.argv[1:]):
        yield
        return
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    import pipenv_purifier as purifier
    native = Path(os.environ.get('PIPENV_PURIFIER_TOOL_LOCKFILE', root / 'Pipfile.lock'))
    lock = purifier.read_pipfile_lock(str(native))
    purifier.check_purifier_lock(str(root), lock, str(lockfile), str(native))
    state = lockfile.parent / '.pipenv-purifier'
    inputs = state / 'inputs'
    if not inputs.exists():
        state.mkdir(exist_ok=True)
        (state / '.gitignore').write_text('*\n')
        purifier.nix_build(str(root), 'prefetch', str(lockfile), str(native), out_link=str(inputs))
    configuration = inputs / 'python-inputs.json'
    if configuration.exists():
        os.environ['PIPENV_PURIFIER_BINDINGS'] = str(configuration)
    # Run/test/editor commands use the ordinary project directory. Installs
    # use a temporary native lock rebound to this machine's Nix inputs.
    if not any(argument in ('sync', 'install') for argument in sys.argv[1:]):
        yield
        return
    environment = root / '.venv'
    if not (environment / 'bin/python').exists():
        subprocess.run([str(inputs / 'python'), '-m', 'venv', str(environment)], check=True)
    with tempfile.TemporaryDirectory(prefix='pipenv-native-') as temporary:
        temporary = Path(temporary)
        provided = json.loads(configuration.read_text())['modules'] if configuration.exists() else {}
        with (inputs / 'direct.json').open() as source:
            direct = json.load(source)
        rewritten = purifier.rewrite(lock, direct, lambda path: str((root / path).resolve()),
                                     keep_editable=True, provided=provided)
        shutil.copyfile(root / 'Pipfile', temporary / 'Pipfile')
        (temporary / 'Pipfile.lock').write_text(json.dumps(rewritten, indent=4) + '\n')
        os.environ.update(purifier.offline_env(str(inputs)), PIPENV_PIPFILE=str(temporary / 'Pipfile'),
                          VIRTUAL_ENV=str(environment))
        yield


def main():
    with native_inputs():
        os.environ['PIPENV_PURIFIER_SITE_PATH'] = json.dumps([path for path in sys.path if path and any(part in ('site-packages','dist-packages') for part in Path(path).parts)])
        if os.environ.get('PIPENV_PURIFIER_BINDINGS'):
            os.environ['PIPENV_RESOLVER_PARENT_PYTHON'] = '1'
        sys.path.insert(0, os.environ['PIPENV_PURIFIER_NIX_LIB'])
        import pipenv_pip
        import pipenv.utils.pip
        pipenv.utils.pip.get_runnable_pip = lambda: str(Path(pipenv_pip.__file__).resolve())
        from pipenv.cli import cli
        cli()


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        api = sys.modules.get('pipenv_purifier')
        if api is not None and isinstance(error, api.Error):
            print('pipenv-purifier: ' + str(error), file=sys.stderr)
            raise SystemExit(1)
        raise
