# SPDX-License-Identifier: MIT
"""pipenv-purifier: locks what a Pipenv project needs beyond Pipfile.lock, so
that Nix can build the project offline in its sandbox.

Pipfile.lock pins every package with the hashes of all of its files, but it
records no URLs, and it leaves out the build requirements: the packages that
building a local package, a git checkout or an sdist needs. `pipenv-purifier
lock` looks up the URL of every locked file on its index, resolves the build
requirements with Pipenv itself, and writes both to pipenv-purifier.lock.json
beside Pipfile.lock.
"""

import argparse
import base64
import contextlib
import hashlib
import html.parser
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.error
import urllib.parse
import urllib.request
import zipfile

from packaging.requirements import InvalidRequirement, Requirement

LOCK_FILE = "pipenv-purifier.lock.json"
FORMAT_VERSION = 2

# The build requirements PEP 517 prescribes, and pip uses, for a project
# without a [build-system] table or without its `requires` key.
DEFAULT_BUILD_REQUIRES = ["setuptools>=40.8.0"]

# The backend PEP 517 prescribes, and pip uses, for a project without a
# `build-backend`.
DEFAULT_BUILD_BACKEND = "setuptools.build_meta:__legacy__"

# The keys of a Pipfile.lock package entry that say where the package comes
# from, other than an index.
DIRECT_KINDS = ("git", "file", "path")


class Error(Exception):
    pass


def log(message):
    print(f"pipenv-purifier: {message}", file=sys.stderr)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sri(hexdigest):
    return "sha256-" + base64.b64encode(bytes.fromhex(hexdigest)).decode()


def normalize(name):
    """A project name as PEP 503 normalizes it, which is also the name of
    its page on a simple index."""
    return re.sub(r"[-_.]+", "-", name).lower()


def file_name(url):
    """The file name a distribution has in the flat directory the Nix build
    reads: the last segment of its URL, percent-decoded."""
    return urllib.parse.unquote(urllib.parse.urlparse(url).path.rsplit("/", 1)[-1])


def without_credentials(url):
    """A URL without the user name and password of its host, which the
    lockfile must not record. A consumer whose index needs credentials gives
    the Nix build a fetcher that supplies them."""
    parsed = urllib.parse.urlparse(url)
    if "@" not in parsed.netloc:
        return url
    return urllib.parse.urlunparse(parsed._replace(netloc=parsed.netloc.rsplit("@", 1)[1]))


def is_wheel(name):
    return name.endswith(".whl")


def is_pure_wheel(name):
    """Whether a wheel installs on every platform: its ABI tag is `none` and
    its platform tag is `any`."""
    parts = name[: -len(".whl")].split("-")
    return len(parts) >= 5 and parts[-2] == "none" and parts[-1] == "any"


def package_version(entry):
    return entry.get("version", "").removeprefix("==")


def package_key(name, entry):
    return f"{normalize(name)}=={package_version(entry)}"


def direct_kind(entry):
    """The kind of a package entry of Pipfile.lock: one of DIRECT_KINDS, or
    "index" for a package from an index."""
    for kind in DIRECT_KINDS:
        if kind in entry:
            return kind
    return "index"


def categories(pipfile_lock):
    """The package categories of Pipfile.lock: `default`, `develop` and any
    custom category the Pipfile declares."""
    return [k for k in pipfile_lock if k != "_meta"]


# Index pages


class AnchorParser(html.parser.HTMLParser):
    """Collects the links of a PEP 503 project page."""

    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            href = dict(attrs).get("href")
            if href:
                self.links.append(href)


class Index:
    """A package index of the project's Pipfile, with the files of each
    project page it read."""

    def __init__(self, source):
        self.name = source["name"]
        self.url = os.path.expandvars(source["url"]).rstrip("/")
        self.context = None if source.get("verify_ssl", True) else ssl._create_unverified_context()
        self.pages = {}

    def files(self, project):
        """The files of a project's page, as {sha256: (file name, URL)}."""
        project = normalize(project)
        if project in self.pages:
            return self.pages[project]
        page = f"{self.url}/{project}/"
        request = urllib.request.Request(
            page,
            headers={"Accept": "application/vnd.pypi.simple.v1+json, text/html;q=0.1"},
        )
        def read():
            with urllib.request.urlopen(request, context=self.context) as response:
                return response.headers.get("Content-Type", ""), response.read(), response.geturl()

        try:
            content_type, body, final = fetch_with_retries(f"reading {page}", read)
        except urllib.error.HTTPError as e:
            raise Error(f"the index {self.name} has no page for {project}: {e}") from e
        found = parse_index_page(body, content_type, final)
        self.pages[project] = found
        return found


def parse_index_page(body, content_type, page_url):
    """The files of a project page of a simple index, as {sha256: (file
    name, URL)}: a JSON page (PEP 691) by its `files`, an HTML page (PEP 503)
    by the links with a sha256 fragment. Relative URLs resolve against the
    page's URL, and no URL keeps the credentials of its host."""
    found = {}
    if "json" in content_type:
        for entry in json.loads(body).get("files", []):
            digest = entry.get("hashes", {}).get("sha256")
            if digest:
                url = urllib.parse.urljoin(page_url, entry["url"])
                found[digest] = (entry["filename"], without_credentials(url))
    else:
        parser = AnchorParser()
        parser.feed(body.decode())
        for href in parser.links:
            url = urllib.parse.urljoin(page_url, href)
            parsed = urllib.parse.urlparse(url)
            fragment = urllib.parse.parse_qs(parsed.fragment)
            if "sha256" in fragment:
                plain = urllib.parse.urlunparse(parsed._replace(fragment=""))
                found[fragment["sha256"][0]] = (file_name(plain), without_credentials(plain))
    return found


# Build requirements


def build_requires(pyproject):
    build_system = pyproject.get("build-system")
    if build_system is None or "requires" not in build_system:
        return list(DEFAULT_BUILD_REQUIRES)
    return list(build_system["requires"])


# Asks a build backend for the requirements it adds at build time, through
# the PEP 517 hooks, as pip's build isolation does, and for the version the
# backend gives the package. It runs in the source tree with the static build
# requirements installed, and prints a JSON object. It reads its arguments
# first, because setuptools' legacy backend runs setup.py with an argv of its
# own.
HOOKS_SCRIPT = """
import importlib, json, os, sys, tempfile
name, path, mode = sys.argv[1:4]
sys.path[:0] = json.loads(path)
module, _, attribute = name.partition(":")
backend = importlib.import_module(module)
for part in filter(None, attribute.split(".")):
    backend = getattr(backend, part)
requires = []
for hook in (
    "get_requires_for_build_sdist",
    "get_requires_for_build_wheel",
    "get_requires_for_build_editable",
):
    if hasattr(backend, hook):
        requires += getattr(backend, hook)({})
version = None
if mode == "version" and hasattr(backend, "prepare_metadata_for_build_wheel"):
    out = tempfile.mkdtemp()
    info = backend.prepare_metadata_for_build_wheel(out, {})
    with open(os.path.join(out, info, "METADATA")) as f:
        for line in f:
            if line.startswith("Version:"):
                version = line.split(":", 1)[1].strip()
                break
print(json.dumps({"requires": requires, "version": version}))
"""


def run(args, cwd=None, env=None):
    return subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True, check=False)


class Context:
    """What the lock run shares: the project's indexes, its Python, the
    scratch directory, and the arguments that point pip at the indexes."""

    def __init__(self, root, pipfile_lock, python, workdir):
        self.root = root
        self.python = python
        self.workdir = workdir
        meta = pipfile_lock.get("_meta", {})
        self.sources = meta.get("sources") or [
            {"name": "pypi", "url": "https://pypi.org/simple", "verify_ssl": True}
        ]
        self.indexes = {s["name"]: Index(s) for s in self.sources}
        self.python_version = meta.get("requires", {}).get("python_version")
        urls = [os.path.expandvars(s["url"]) for s in self.sources]
        self.pip_index_args = ["--index-url", urls[0]] + [a for u in urls[1:] for a in ("--extra-index-url", u)]

    def index(self, name):
        if name is None:
            return next(iter(self.indexes.values()))
        if name not in self.indexes:
            raise Error(f"Pipfile.lock names the index {name}, which its sources do not declare")
        return self.indexes[name]

    def env(self, **extra):
        """The environment of the tools the lock run starts. Their caches
        go to the scratch directory."""
        return dict(
            {key: value for key, value in os.environ.items() if key != "PIPENV_PURIFIER_BINDINGS"},
            PIP_CACHE_DIR=os.path.join(self.workdir, "pip-cache"),
            PIPENV_CACHE_DIR=os.path.join(self.workdir, "pipenv-cache"),
            PIPENV_VENV_IN_PROJECT="1",
            PIPENV_YES="1",
            PIPENV_NOSPIN="1",
            PIPENV_PYTHON=self.python,
            PIP_DISABLE_PIP_VERSION_CHECK="1",
            **extra,
        )

    def scratch(self):
        return tempfile.mkdtemp(dir=self.workdir)


def backend_report(ctx, tree, pyproject, static, want_version):
    """The requirements the build backend of a source tree reports through
    its PEP 517 hooks for an sdist, a wheel and an editable install, and the
    version it gives the package when `want_version`. A backend such as
    hatchling asks for `editables` only this way."""
    build_system = pyproject.get("build-system", {})
    backend = build_system.get("build-backend", DEFAULT_BUILD_BACKEND)
    backend_path = [os.path.join(tree, p) for p in build_system.get("backend-path", [])]
    venv = ctx.scratch()
    result = run([ctx.python, "-m", "venv", venv])
    if result.returncode != 0:
        raise Error(f"creating a virtual environment failed:\n{result.stderr.strip()}")
    pip = [os.path.join(venv, "bin", "python"), "-m", "pip"]
    result = run([*pip, "install", "--quiet", *ctx.pip_index_args, *static], cwd=tree, env=ctx.env())
    if result.returncode != 0:
        raise Error(f"installing the build requirements {', '.join(static)} failed:\n{result.stderr.strip()}")
    result = run(
        [
            os.path.join(venv, "bin", "python"),
            "-c",
            HOOKS_SCRIPT,
            backend,
            json.dumps(backend_path),
            "version" if want_version else "requires",
        ],
        cwd=tree,
    )
    if result.returncode != 0:
        raise Error(f"the build backend {backend} failed to report its requirements:\n{result.stderr.strip()}")
    return json.loads(result.stdout.strip().splitlines()[-1])


def tree_pyproject(directory):
    """The pyproject.toml of a source tree, or {} when it has none."""
    path = os.path.join(directory, "pyproject.toml")
    if not os.path.exists(path):
        return {}
    with open(path, "rb") as f:
        return tomllib.load(f)


def tree_requirements(ctx, tree, want_version=False):
    """Every build requirement of a source tree, the static ones of its
    [build-system] table and the ones its backend adds, and with
    `want_version` the version its backend gives it. When the backend cannot
    report, the static requirements stand, and a build that needs more fails
    in the sandbox with pip's error."""
    pyproject = tree_pyproject(tree)
    static = build_requires(pyproject)
    try:
        report = backend_report(ctx, tree, pyproject, static, want_version)
    except Error as e:
        log(f"using only the static build requirements of {tree}: {e}")
        return static, None
    requires = list(static)
    for requirement in report["requires"]:
        if requirement not in requires:
            requires.append(requirement)
    return requires, report["version"]


def scratch_copy(ctx, tree):
    """A writable copy of a source tree. A backend may write into the tree
    while it reports its requirements, as setuptools writes its egg-info, so
    the hooks run on a copy rather than on the project or a store path."""
    copy = os.path.join(ctx.scratch(), "tree")
    shutil.copytree(tree, copy, ignore=shutil.ignore_patterns(".venv", "__pycache__", "dist"))
    run(["chmod", "-R", "u+w", copy])
    return copy


def unpack(ctx, archive):
    """Unpacks an sdist or source archive and returns its source tree: the
    single top directory, as in an sdist or a GitHub archive, or else the
    unpacked root."""
    target = ctx.scratch()
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as z:
            z.extractall(target)
    else:
        with tarfile.open(archive) as t:
            t.extractall(target, filter="data")
    entries = os.listdir(target)
    if len(entries) == 1 and os.path.isdir(os.path.join(target, entries[0])):
        return os.path.join(target, entries[0])
    return target


ATTEMPTS = 3


def fetch_with_retries(what, read):
    """Runs `read`, which reads from the network, and tries again when the
    connection fails partway, as a long lock run over a busy network meets
    now and then. After the last attempt the error says what failed and
    what to run."""
    for attempt in range(1, ATTEMPTS + 1):
        try:
            return read()
        except urllib.error.HTTPError:
            raise
        except (urllib.error.URLError, http.client.HTTPException, ConnectionError, TimeoutError) as e:
            if attempt == ATTEMPTS:
                raise Error(
                    f"{what} failed {ATTEMPTS} times, the last time with {e!r}; "
                    "check the network and run `pipenv-purifier lock` again"
                ) from e
            log(f"{what} failed ({e!r}); trying again")


def download(ctx, url, directory):
    """Downloads a file and returns its path."""
    target = os.path.join(tempfile.mkdtemp(dir=directory), file_name(url) or "download")

    def read():
        with urllib.request.urlopen(url) as response, open(target, "wb") as out:
            shutil.copyfileobj(response, out)
        return target

    return fetch_with_retries(f"downloading {url}", read)


def pipfile_entry(requirements):
    """The [packages] entry of a throwaway Pipfile for every requirement on
    one project name: the specifiers joined, the extras merged, and the
    markers kept when only one requirement has them."""
    specifiers = ",".join(str(r.specifier) for r in requirements if str(r.specifier))
    extras = sorted({e for r in requirements for e in r.extras})
    markers = {str(r.marker) for r in requirements if r.marker is not None}
    entry = {"version": specifiers or "*"}
    if extras:
        entry["extras"] = extras
    if len(markers) == 1 and len(requirements) == 1:
        entry["markers"] = markers.pop()
    return entry


def toml_value(value):
    """A TOML value for the throwaway Pipfile: strings, booleans and lists
    of strings, which JSON writes the way TOML reads them, and inline
    tables."""
    if isinstance(value, dict):
        return "{ " + ", ".join(f"{json.dumps(k)} = {toml_value(v)}" for k, v in value.items()) + " }"
    return json.dumps(value)


def resolve_build_requirements(ctx, requires, pinned):
    """Resolves one set of build requirements with `pipenv lock`, at the
    versions Pipfile.lock pins wherever the set allows them, and returns
    the `default` packages of the resulting Pipfile.lock. `pinned` maps a
    normalized project name to the one version Pipfile.lock pins for it.
    A package that Pipfile.lock pins and the set resolves to another version
    is pinned in the throwaway Pipfile, and the set is resolved again. When
    the set does not allow the pinned version, the set keeps its own, and
    the lockfile records the files of that version."""
    pins = {}
    resolved = resolve_pinned(ctx, requires, pins)
    for _ in range(5):
        drift = {
            name: pinned[normalize(name)]
            for name, package in resolved.items()
            if normalize(name) in pinned and package_version(package) != pinned[normalize(name)]
        }
        if not drift:
            break
        pins.update(drift)
        try:
            resolved = resolve_pinned(ctx, requires, pins)
        except Error as e:
            log(f"keeping {', '.join(f'{n}=={v}' for n, v in sorted(drift.items()))} of Pipfile.lock out of the build requirements {', '.join(requires)}, which do not allow them: {e}")
            for name in drift:
                del pins[name]
            break
    return resolved


def resolve_pinned(ctx, requires, pins):
    """Resolves a set of build requirements with `pipenv lock`, on a
    throwaway Pipfile that depends on them and on the versions `pins` names,
    and reads the project's indexes."""
    by_name = {}
    for text in requires:
        try:
            requirement = Requirement(text)
        except InvalidRequirement as e:
            raise Error(f"the build requirement {text!r} is not a valid requirement: {e}") from e
        if requirement.url:
            raise Error(f"the build requirement {text!r} names a URL; build requirements come from an index")
        by_name.setdefault(normalize(requirement.name), []).append(requirement)
    project = ctx.scratch()
    lines = []
    for source in ctx.sources:
        lines.append("[[source]]")
        for key in ("name", "url", "verify_ssl"):
            if key in source:
                lines.append(f"{key} = {toml_value(source[key])}")
        lines.append("")
    for name, version in pins.items():
        by_name.setdefault(normalize(name), []).append(Requirement(f"{name}=={version}"))
    lines.append("[packages]")
    for name, requirements in sorted(by_name.items()):
        lines.append(f"{json.dumps(name)} = {toml_value(pipfile_entry(requirements))}")
    if ctx.python_version:
        lines += ["", "[requires]", f"python_version = {json.dumps(ctx.python_version)}"]
    with open(os.path.join(project, "Pipfile"), "w") as f:
        f.write("\n".join(lines) + "\n")
    result = run(["pipenv", "lock"], cwd=project, env=ctx.env())
    if result.returncode != 0:
        raise Error((result.stderr or result.stdout).strip())
    with open(os.path.join(project, "Pipfile.lock")) as f:
        return json.load(f).get("default", {})


# Git


def git_url(value):
    return value.removeprefix("git+")


def prefetch_git(url, rev):
    """Fetches a commit with its submodules, as pip checks it out, and
    returns the store path of the checkout and its NAR hash."""
    result = run(["nix-prefetch-git", "--url", url, "--rev", rev, "--fetch-submodules", "--quiet"])
    if result.returncode != 0:
        raise Error(f"nix-prefetch-git could not fetch {url} at {rev}:\n{result.stderr.strip()}")
    info = json.loads(result.stdout)
    return info["path"], info["hash"]


def clone(ctx, url, rev):
    """A clone of a repository at a commit, with its history, so that a
    backend that reads its version from git, such as setuptools-scm, finds
    it."""
    target = os.path.join(ctx.scratch(), "clone")
    for args in (
        ["git", "clone", "--quiet", "--filter=blob:none", url, target],
        ["git", "-C", target, "checkout", "--quiet", rev],
        ["git", "-C", target, "submodule", "update", "--quiet", "--init", "--recursive"],
    ):
        result = run(args)
        if result.returncode != 0:
            raise Error(f"`{' '.join(args)}` failed:\n{result.stderr.strip()}")
    return target


# Outputs


def wheel_scripts(wheel):
    """The console and GUI scripts a wheel installs, from the
    entry_points.txt of its .dist-info."""
    with zipfile.ZipFile(wheel) as z:
        names = [n for n in z.namelist() if n.endswith(".dist-info/entry_points.txt") and n.count("/") == 1]
        if not names:
            return []
        text = z.read(names[0]).decode()
    scripts = []
    section = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
        elif "=" in line and section in ("console_scripts", "gui_scripts"):
            scripts.append(line.split("=", 1)[0].strip())
    return sorted(scripts)


def build_outputs(ctx, name, tree):
    """Builds a local package's sdist and wheel, as the Nix build does, and
    returns what the lockfile records about them: the file names Nix exposes
    without building, whether the wheel is the same on every system, and
    the scripts the package installs."""
    out = ctx.scratch()
    # `build` comes with the Python this program runs on. It builds in an
    # isolated environment that pip fills from the project's indexes.
    env = ctx.env(PIP_INDEX_URL=ctx.pip_index_args[1], PIP_EXTRA_INDEX_URL=" ".join(ctx.pip_index_args[3::2]))
    result = run([sys.executable, "-m", "build", "--outdir", out, scratch_copy(ctx, tree)], env=env)
    if result.returncode != 0:
        raise Error(f"building {name} failed:\n{(result.stderr or result.stdout).strip()}")
    built = sorted(os.listdir(out))
    wheels = [n for n in built if is_wheel(n)]
    sdists = [n for n in built if not is_wheel(n)]
    if len(wheels) != 1 or len(sdists) != 1:
        raise Error(f"building {name} made {', '.join(built)}, not one sdist and one wheel")
    wheel = wheels[0]
    # The Nix library reads the version and whether the wheel is the same
    # on every system from the wheel's name.
    return {
        "sdist": sdists[0],
        "wheel": wheel,
        "scripts": wheel_scripts(os.path.join(out, wheel)),
    }


# The lock


def inside_project(path):
    return not (path == ".." or path.startswith(("/", "../")))


def tree_files(root, pipfile_lock):
    """The pyproject.toml files of the local source trees inside the
    project. Their build requirements are in the lockfile, so the lockfile
    has to change with them."""
    files = set()
    for category in categories(pipfile_lock):
        for entry in pipfile_lock[category].values():
            path = entry.get("path")
            if path is not None and inside_project(path):
                candidate = os.path.normpath(os.path.join(path, "pyproject.toml"))
                if os.path.exists(os.path.join(root, candidate)):
                    files.add(candidate)
    return sorted(files)


def inputs_hash(root, pipfile_lock, tool_lock):
    """The hash the Nix library compares to tell whether the lockfile still
    matches Pipfile.lock, the one at `tool_lock`, and the pyproject.toml
    files of the local source trees in the project. lib-overlays/default/lock.nix
    computes the same text."""
    text = f"Pipfile.lock {sha256_file(tool_lock)}\n" + "".join(
        f"{f} {sha256_file(os.path.join(root, f))}\n" for f in tree_files(root, pipfile_lock)
    )
    return hashlib.sha256(text.encode()).hexdigest()


def read_pipfile_lock(path):
    """The Pipfile.lock at `path`, with an error that says what to run when
    it is missing or damaged."""
    if not os.path.exists(path):
        raise Error(f"{path} does not exist; run `pipenv-purifier lock`, which writes it with `pipenv lock`")
    try:
        with open(path) as f:
            pipfile_lock = json.load(f)
    except json.JSONDecodeError as e:
        raise Error(f"{path} is not valid JSON ({e}); run `pipenv lock` to write it again") from e
    if not isinstance(pipfile_lock, dict) or "_meta" not in pipfile_lock:
        raise Error(f"{path} is not a Pipfile.lock; run `pipenv lock` to write it again")
    return pipfile_lock


def content_hash(lockfile):
    """The hash a lockfile records of its own content: the SHA-256 of its
    JSON without the `contentHash` field, with sorted keys and no
    whitespace, which is the text Nix's builtins.toJSON writes of it.
    lib-overlays/default/lock.nix computes the same hash, so an edit to the lockfile is
    found before anything is fetched."""
    rest = {k: v for k, v in lockfile.items() if k != "contentHash"}
    text = json.dumps(rest, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(text.encode()).hexdigest()


@contextlib.contextmanager
def in_tree(root, tool_lock, write_back):
    """Runs Pipenv on the Pipfile.lock at `tool_lock`. Pipenv reads
    Pipfile.lock beside the Pipfile, where it also resolves the local paths
    of the Pipfile, so a Pipfile.lock outside the project is copied into the
    project for the block: the outside copy, or the copy in the project when
    there is no outside copy yet. With `write_back`, the Pipfile.lock that
    Pipenv leaves is copied out to `tool_lock` afterwards. The copy in the
    project is then restored as it was."""
    tree = os.path.join(root, "Pipfile.lock")
    if os.path.abspath(tool_lock) == os.path.abspath(tree):
        yield
        return
    saved = None
    if os.path.exists(tree):
        with open(tree, "rb") as f:
            saved = f.read()
    try:
        if os.path.exists(tool_lock):
            shutil.copyfile(tool_lock, tree)
        yield
        if write_back and os.path.exists(tree):
            os.makedirs(os.path.dirname(os.path.abspath(tool_lock)), exist_ok=True)
            shutil.copyfile(tree, tool_lock)
    finally:
        if saved is None:
            if os.path.exists(tree):
                os.remove(tree)
        else:
            with open(tree, "wb") as f:
                f.write(saved)


def pipfile_matches(root, python):
    """Whether the Pipfile.lock in the project matches the Pipfile. `pipenv
    verify` compares the hash in _meta with the hash of the Pipfile."""
    if not os.path.exists(os.path.join(root, "Pipfile.lock")):
        return False
    return run(["pipenv", "verify"], cwd=root, env=dict(os.environ, PIPENV_PYTHON=python)).returncode == 0


def ensure_pipfile_lock(root, python, tool_lock):
    """Pipfile.lock as Pipenv resolved it, at `tool_lock`. A Pipfile.lock
    that matches the Pipfile stays as it is. When it is missing or no longer
    matches the Pipfile, as after adding a package to the Pipfile by hand,
    `pipenv lock` writes it."""
    with in_tree(root, tool_lock, write_back=True):
        if os.environ.get("PIPENV_PURIFIER_BINDINGS") or not pipfile_matches(root, python):
            log("Pipfile.lock is missing or does not match the Pipfile; writing it with `pipenv lock`")
            result = subprocess.run(["pipenv", "lock"], cwd=root, env=dict(os.environ, PIPENV_PYTHON=python), check=False)
            if result.returncode != 0:
                raise Error("`pipenv lock` failed; its error above says why")
    return read_pipfile_lock(tool_lock)


def pipfile_lock_pins(pipfile_lock):
    """The packages of an index that Pipfile.lock pins: their keys, and the
    version of each project name that Pipfile.lock pins at one version."""
    keys = set()
    versions = {}
    for category in categories(pipfile_lock):
        for name, entry in pipfile_lock[category].items():
            if direct_kind(entry) == "index":
                keys.add(package_key(name, entry))
                versions.setdefault(normalize(name), set()).add(package_version(entry))
    return keys, {name: v.pop() for name, v in versions.items() if len(v) == 1}


def native_lock(root, python, lock_path, tool_lock):
    """Writes the lockfile, which records only what Pipfile.lock cannot:
    - `urls`: the URL of each file of an index, by the sha256 that
      Pipfile.lock, or `buildPackages`, lists for it. The file's name is the
      last segment of its URL.
    - `buildPackages`: the sha256 hashes of the files of each package that
      only the build requirements need, which Pipfile.lock does not pin.
    - `buildRequirements` and `builds`: the resolved sets of build
      requirements, and the set that building each package needs.
    - `sources`: the hash of the checkout of each package from git, which
      Pipfile.lock pins by commit, with the version a backend that reads git
      gives it, and the hash of each file from a URL that Pipfile.lock
      lists no hash for.
    - `outputs`: the names of the sdist and wheel of each local package, and
      its scripts, which Nix knows without building.
    - `inputsHash` and `contentHash`, which tell a stale lockfile and an
      edited one."""
    pipfile_lock = ensure_pipfile_lock(root, python, tool_lock)
    locked_keys, pinned = pipfile_lock_pins(pipfile_lock)

    urls = {}
    # Every file of an index that the lock run found, by name, as (sha256,
    # URL), and the files of each package by key.
    named = {}
    packages = {}
    build_packages = {}
    requirement_sets = []
    set_index = {}
    builds = {}
    sources = {}
    outputs = {}
    pending = []

    def add_url(digest, filename, url):
        if file_name(url) != filename:
            raise Error(f"the index serves {filename} at {url}, whose last segment names another file")
        known = named.get(filename)
        if known is not None and known != (digest, url):
            raise Error(f"two locked files are both named {filename}: {known[1]} and {url}")
        named[filename] = (digest, url)
        urls[digest] = url

    def request(key, requires):
        canonical = tuple(sorted(requires))
        if canonical not in set_index:
            set_index[canonical] = len(requirement_sets)
            requirement_sets.append({"requires": list(canonical)})
            pending.append(canonical)
        builds[key] = set_index[canonical]

    def index_files(ctx, name, entry):
        """The locked files of an index package, looked up by hash on its
        index, as {"wheels": [...], "sdist": ...}."""
        key = package_key(name, entry)
        if key in packages:
            return packages[key]
        index = ctx.index(entry.get("index"))
        page = index.files(name)
        wheels = []
        sdist = None
        missing = []
        for locked in entry.get("hashes", []):
            algorithm, _, digest = locked.partition(":")
            if algorithm != "sha256":
                raise Error(f"{key} has a {algorithm} hash; pipenv-purifier reads sha256 hashes")
            if digest not in page:
                missing.append(digest)
                continue
            filename, url = page[digest]
            add_url(digest, filename, url)
            if is_wheel(filename):
                wheels.append(filename)
            elif filename.endswith((".tar.gz", ".zip", ".tar.bz2", ".tar.xz", ".tgz")):
                if sdist is not None:
                    raise Error(f"{key} has two sdists, {sdist} and {filename}")
                sdist = filename
            else:
                log(f"leaving out {filename} of {key}, which is neither a wheel nor an sdist")
        if not wheels and sdist is None:
            raise Error(f"the index {index.name} has none of the locked files of {key}")
        if missing:
            log(f"the index {index.name} no longer has {len(missing)} locked file(s) of {key}; locking the rest")
        files = {"wheels": sorted(wheels), "sdist": sdist}
        packages[key] = files
        return files

    def may_need_build(files):
        """Whether some platform may have to build a package from its
        sdist: it has an sdist and no wheel that installs everywhere. The
        Nix library decides per system and Python version which of these it
        actually builds."""
        return files["sdist"] is not None and not any(is_pure_wheel(w) for w in files["wheels"])

    def request_sdist(ctx, key, files):
        log(f"reading the build requirements of {key}")
        expected, url = named[files["sdist"]]
        archive = download(ctx, url, ctx.workdir)
        if sha256_file(archive) != expected:
            raise Error(f"the sdist of {key} does not match its locked hash")
        requires, _ = tree_requirements(ctx, unpack(ctx, archive))
        request(key, requires)

    with tempfile.TemporaryDirectory(prefix="pipenv-purifier-") as workdir:
        ctx = Context(root, pipfile_lock, python, workdir)
        configuration = os.environ.get("PIPENV_PURIFIER_BINDINGS")
        provided = json.loads(Path(configuration).read_text())["modules"] if configuration else {}
        for category in categories(pipfile_lock):
            for name, entry in pipfile_lock[category].items():
                if normalize(name) in provided:
                    continue
                kind = direct_kind(entry)
                key = normalize(name)
                if kind == "index":
                    files = index_files(ctx, name, entry)
                    key = package_key(name, entry)
                    if may_need_build(files) and key not in builds:
                        request_sdist(ctx, key, files)
                elif key in sources or key in builds:
                    continue
                elif kind == "git":
                    url = git_url(entry["git"])
                    rev = entry.get("ref")
                    if not rev or not re.fullmatch(r"[0-9a-f]{40}", rev):
                        raise Error(f"Pipfile.lock pins {name} to {rev!r}, which is no commit; run `pipenv lock` again")
                    log(f"fetching {name} from {url} at {rev}")
                    # The Nix library fetches the commit with its submodules
                    # and without .git, because the build installs a wheel
                    # it makes from the checkout.
                    _, nar_hash = prefetch_git(url, rev)
                    checkout = clone(ctx, url, rev)
                    subdirectory = entry.get("subdirectory")
                    tree = os.path.join(checkout, subdirectory) if subdirectory else checkout
                    log(f"reading the build requirements of {name}")
                    requires, version = tree_requirements(ctx, tree, want_version=True)
                    request(key, requires)
                    sources[key] = {"hash": nar_hash}
                    if version is not None:
                        sources[key]["version"] = version
                elif kind == "file":
                    url = entry["file"]
                    if url != without_credentials(url):
                        raise Error(f"Pipfile.lock names {name} by a URL with credentials; give the Nix build a fetchurl that supplies them instead")
                    log(f"downloading {name} from {url}")
                    downloaded = download(ctx, url, workdir)
                    digest = sha256_file(downloaded)
                    locked = [h.partition(":")[2] for h in entry.get("hashes", [])]
                    if locked and digest not in locked:
                        raise Error(f"{url} has sha256 {digest}, which Pipfile.lock does not list for {name}")
                    if not locked:
                        sources[key] = {"hash": sri(digest)}
                    if not is_wheel(url):
                        log(f"reading the build requirements of {name}")
                        requires, _ = tree_requirements(ctx, unpack(ctx, downloaded))
                        request(key, requires)
                elif kind == "path":
                    path = entry["path"]
                    target = path if os.path.isabs(path) else os.path.normpath(os.path.join(root, path))
                    if os.path.isdir(target):
                        log(f"reading the build requirements of {name}")
                        requires, _ = tree_requirements(ctx, scratch_copy(ctx, target))
                        request(key, requires)
                    elif not is_wheel(target):
                        log(f"reading the build requirements of {name}")
                        requires, _ = tree_requirements(ctx, unpack(ctx, target))
                        request(key, requires)

        while pending:
            canonical = pending.pop(0)
            entry = requirement_sets[set_index[canonical]]
            log(f"resolving the build requirements {', '.join(canonical)}")
            try:
                resolved = resolve_build_requirements(ctx, list(canonical), pinned)
            except Error as e:
                log(f"could not resolve {', '.join(canonical)}: {e}")
                entry["error"] = str(e)
                entry["packages"] = []
                continue
            records = []
            for name, package in sorted(resolved.items()):
                if direct_kind(package) != "index":
                    raise Error(f"the build requirement {name} resolved to a {direct_kind(package)} source; build requirements come from an index")
                files = index_files(ctx, name, package)
                key = package_key(name, package)
                # The set records each package by its key alone. Its markers
                # are pip's to apply when it installs the set.
                records.append(key)
                if key not in locked_keys:
                    build_packages[key] = sorted(h.partition(":")[2] for h in package.get("hashes", []))
                if may_need_build(files) and key not in builds:
                    request_sdist(ctx, key, files)
            entry["packages"] = records

        local = local_package_paths(root, pipfile_lock)
        for name in sorted(local):
            path = local[name]
            log(f"building {name} to record its outputs")
            outputs[name] = build_outputs(ctx, name, os.path.normpath(os.path.join(root, path)))

    result = {
        "version": FORMAT_VERSION,
        "inputsHash": inputs_hash(root, pipfile_lock, tool_lock),
        "urls": dict(sorted(urls.items())),
        "buildPackages": dict(sorted(build_packages.items())),
        "buildRequirements": requirement_sets,
        "builds": dict(sorted(builds.items())),
        "sources": dict(sorted(sources.items())),
        "outputs": dict(sorted(outputs.items())),
    }
    result["contentHash"] = content_hash(result)
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    with open(lock_path, "w") as f:
        json.dump(result, f, indent=2)
        f.write("\n")
    log(
        f"wrote {os.path.basename(lock_path)}: the URLs of {len(urls)} files, "
        f"{len(build_packages)} packages beyond Pipfile.lock, {len(requirement_sets)} sets of build requirements"
    )


def native_update(root, python, lock_path, tool_lock, names):
    """Updates both lockfiles: Pipenv re-resolves every package with `pipenv
    lock`, or the packages `names` with `pipenv upgrade`, which writes
    Pipfile.lock and installs nothing, and the lock run then writes the
    pipenv-purifier lockfile for the new Pipfile.lock."""
    args = ["pipenv", "upgrade", *names] if names else ["pipenv", "lock"]
    log(f"re-resolving with `{' '.join(args)}`")
    with in_tree(root, tool_lock, write_back=True):
        result = subprocess.run(args, cwd=root, env=dict(os.environ, PIPENV_PYTHON=python), check=False)
        if result.returncode != 0:
            raise Error(f"`{' '.join(args)}` failed; its error above says why")
    native_lock(root, python, lock_path, tool_lock)


@contextlib.contextmanager
def input_context(lock_path, references=None, refresh=False, python=None):
    try:
        previous = json.loads(Path(lock_path).read_text()).get("projectInputs", [])
    except (OSError, ValueError):
        previous = []
    if references is None:
        references = [entry["reference"] for entry in previous]
    if not references:
        yield [], {}
        return
    sys.path.insert(0, os.path.join(os.environ["PIPENV_PURIFIER_LIBRARY"], "tools"))
    sys.path.insert(0, os.environ["PIPENV_PURIFIER_NIX_LIB"])
    import project_inputs
    import python_bindings
    records = project_inputs.pin(references, previous, refresh)
    state = Path(lock_path).parent / ".pipenv-purifier"
    state.mkdir(exist_ok=True)
    (state / ".gitignore").write_text("*\n")
    views = project_inputs.python_views(records, state / "project-inputs")
    configuration = python_bindings.write(views, [entry["nativeRepository"] for entry in previous], state / "bindings", python=python)
    old = os.environ.get("PIPENV_PURIFIER_BINDINGS")
    os.environ["PIPENV_PURIFIER_BINDINGS"] = str(configuration)
    try:
        yield [entry | {"nativeRepository": str(view["repository"])}
               for entry, view in zip(records, views, strict=True)], json.loads(configuration.read_text())["modules"]
    finally:
        if old is None:
            os.environ.pop("PIPENV_PURIFIER_BINDINGS", None)
        else:
            os.environ["PIPENV_PURIFIER_BINDINGS"] = old


def write_inputs(lock_path, records, modules):
    if not records:
        return
    result = json.loads(Path(lock_path).read_text())
    result["projectInputs"] = records
    result["projectInputNames"] = sorted(modules)
    result["contentHash"] = content_hash(result)
    Path(lock_path).write_text(json.dumps(result, indent=2) + "\n")


def lock(root, python, lock_path, tool_lock, inputs=None):
    with input_context(lock_path, inputs, python=python) as (records, modules):
        native_lock(root, python, lock_path, tool_lock)
        write_inputs(lock_path, records, modules)


def update(root, python, lock_path, tool_lock, names, inputs=None):
    with input_context(lock_path, inputs, refresh=True, python=python) as (records, modules):
        native_update(root, python, lock_path, tool_lock, names)
        write_inputs(lock_path, records, modules)


# Nix builds, prefetch and publish

# Where `prefetch` keeps its garbage-collector root, beside the lockfile.
ROOT_DIR = ".pipenv-purifier"


def nix_build(root, attribute, lock_path, tool_lock, out_link=None):
    """Builds, with the Nix library this program was installed with, an
    attribute of pkgs/cli/cli.nix for the project, and returns the store
    path. With `out_link`, the result is also a garbage-collector root at
    that path."""
    library = os.environ.get("PIPENV_PURIFIER_NIX_LIB")
    nixpkgs = os.environ.get("PIPENV_PURIFIER_NIXPKGS")
    purifier = os.environ.get("PIPENV_PURIFIER_LIBRARY")
    if not library or not nixpkgs or not purifier:
        raise Error(
            "this command needs the pipenv-purifier package, which sets PIPENV_PURIFIER_NIX_LIB, "
            "PIPENV_PURIFIER_NIXPKGS and PIPENV_PURIFIER_LIBRARY"
        )
    args = [
        "nix-build",
        *(["--out-link", out_link] if out_link else ["--no-out-link"]),
        os.path.join(library, "../cli/cli.nix"),
        "--arg", "nixpkgs", nixpkgs,
        "--argstr", "purifier", purifier,
        "--argstr", "src", root,
        "--argstr", "attribute", attribute,
        "--argstr", "lockFile", lock_path,
        "--argstr", "pipfileLock", os.path.abspath(tool_lock),
    ]
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, check=False)
    if result.returncode != 0:
        raise Error(f"the Nix build of the {attribute} failed; its error above says what to run")
    return result.stdout.strip().splitlines()[-1]


def offline_env(inputs):
    """The environment in which Pipenv installs from the locked files Nix
    fetched and nothing else. A PYTHONPATH of the shell, as a Nix shell
    with Python packages sets one, is left out, because pip would take a
    package there as installed and leave the locked one out of .venv."""
    environment = {k: v for k, v in os.environ.items() if k != "PYTHONPATH"}
    configuration = os.path.join(inputs, "python-inputs.json")
    if os.path.exists(configuration):
        environment["PIPENV_PURIFIER_BINDINGS"] = configuration
    return dict(
        environment,
        PIP_NO_INDEX="1",
        PIP_FIND_LINKS=os.path.join(inputs, "wheelhouse"),
        PIP_DISABLE_PIP_VERSION_CHECK="1",
        PIPENV_YES="1",
        PIPENV_NOSPIN="1",
        # Pipenv notes that it installs into the virtual environment it
        # runs in, which is what `prefetch` asks of it.
        PIPENV_VERBOSITY="-1",
    )


def check_purifier_lock(root, pipfile_lock, path, tool_lock):
    """The pipenv-purifier lockfile at `path` exists, is unedited, and was
    made for the Pipfile.lock at `tool_lock`, as the Nix library checks too.
    The commands check it before they build, so that the error names the
    file and the command to run."""
    if not os.path.exists(path):
        raise Error(f"{path} does not exist; run `pipenv-purifier lock` first")
    try:
        with open(path) as f:
            purifier_lock = json.load(f)
    except json.JSONDecodeError as e:
        raise Error(f"{path} is not valid JSON ({e}); run `pipenv-purifier lock` to write it again") from e
    if not isinstance(purifier_lock, dict) or purifier_lock.get("version") != FORMAT_VERSION:
        raise Error(f"{path} is not a lockfile of this pipenv-purifier; run `pipenv-purifier lock` to write it again")
    if purifier_lock.get("contentHash") != content_hash(purifier_lock):
        raise Error(f"{path} was edited after `pipenv-purifier lock` wrote it; run `pipenv-purifier lock` to write it again")
    if purifier_lock.get("inputsHash") != inputs_hash(root, pipfile_lock, tool_lock):
        raise Error(
            f"{LOCK_FILE} no longer matches Pipfile.lock or the pyproject.toml of a local package, "
            "as after `pipenv install`; run `pipenv-purifier lock`"
        )


def prefetch(root, lock_path, tool_lock, inputs=None, categories_arg=None):
    """Realizes in the Nix store everything the development loop needs: the
    Python of the build, and the locked files of every category for this
    system, development and test packages included. A garbage-collector root
    in .pipenv-purifier/ beside the lockfile keeps them. Then it installs the
    project's .venv from them, offline: the packages of an index with their
    hashes, the packages from git and URLs from their wheels and files, and
    the local packages as Pipfile.lock says, editable or not. Pipenv finds
    the .venv afterwards, so `pipenv run` and `pipenv shell` work with no
    network, and so does an editor that uses the .venv's Python."""
    pipfile_lock = read_pipfile_lock(tool_lock)
    with in_tree(root, tool_lock, write_back=False):
        matches = pipfile_matches(root, sys.executable)
    if not matches:
        raise Error(
            "Pipfile.lock does not match the Pipfile, as after adding a package to the Pipfile by hand; "
            "run `pipenv-purifier lock`, which writes Pipfile.lock with `pipenv lock` first"
        )
    check_purifier_lock(root, pipfile_lock, lock_path, tool_lock)
    source = inputs
    if inputs is None:
        log("fetching the locked files with Nix")
        source = os.path.join(os.path.dirname(lock_path), ROOT_DIR, "inputs")
        os.makedirs(os.path.dirname(source), exist_ok=True)
        inputs = nix_build(root, "prefetch", lock_path, tool_lock, out_link=source)
    state_input = Path(lock_path).parent / ROOT_DIR / "inputs"
    if not state_input.exists():
        state_input.parent.mkdir(exist_ok=True)
        (state_input.parent / ".gitignore").write_text("*\n")
        state_input.symlink_to(Path(inputs).resolve())
    with open(os.path.join(inputs, "direct.json")) as f:
        direct = json.load(f)
    configuration = Path(inputs) / "python-inputs.json"
    provided = json.loads(configuration.read_text())["modules"] if configuration.exists() else {}
    venv = os.path.join(root, ".venv")
    python = os.path.join(venv, "bin", "python")
    if not os.path.exists(python):
        result = subprocess.run([os.path.join(inputs, "python"), "-m", "venv", venv], check=False)
        if result.returncode != 0:
            raise Error(f"creating {venv} failed")
    with tempfile.TemporaryDirectory(prefix="pipenv-purifier-") as workdir:
        rewritten = rewrite(pipfile_lock, direct, lambda p: p if os.path.isabs(p) else os.path.normpath(os.path.join(root, p)), keep_editable=True, provided=provided)
        shutil.copy(os.path.join(root, "Pipfile"), os.path.join(workdir, "Pipfile"))
        with open(os.path.join(workdir, "Pipfile.lock"), "w") as f:
            json.dump(rewritten, f, indent=4)
        args = ["pipenv", "sync"]
        if categories_arg:
            args += ["--categories", " ".join(categories_arg)]
        else:
            args += ["--dev"]
        result = subprocess.run(
            args,
            cwd=root,
            env=dict(offline_env(inputs), PIPENV_PIPFILE=os.path.join(workdir, "Pipfile"), VIRTUAL_ENV=venv),
            check=False,
        )
        if result.returncode != 0:
            raise Error("`pipenv sync` failed")
    log(
        f"installed {venv} from the files in {source}; "
        "`pipenv run` and `pipenv shell` use it with no network, and so does an editor pointed at .venv/bin/python"
    )


def rewrite(pipfile_lock, direct, local_path, keep_editable, provided=None):
    """A copy of Pipfile.lock in which every package from git is a path to
    the wheel Nix built of it, every package from a URL a path to its locked
    file, and every local path absolute. `prefetch` keeps local packages
    editable when Pipfile.lock says so."""
    out = json.loads(json.dumps(pipfile_lock))
    for category in categories(out):
        for name, entry in out[category].items():
            module = (provided or {}).get(normalize(name))
            if module:
                for key in ("git", "ref", "file", "subdirectory", "hashes", "path", "editable", "version", "index"):
                    entry.pop(key, None)
                entry.update(path=module["wheel"], editable=False)
                continue
            kind = direct_kind(entry)
            if kind in ("git", "file"):
                target = direct.get(normalize(name))
                if target is None:
                    raise Error(f"the Nix inputs have no locked source for {name}; run `pipenv-purifier lock`")
                if os.path.isdir(target):
                    # The directory Nix built a git package's wheel into.
                    wheels = [n for n in os.listdir(target) if is_wheel(n)]
                    if len(wheels) != 1:
                        raise Error(f"the Nix build of {name} made {', '.join(sorted(os.listdir(target)))}, not one wheel")
                    target = os.path.join(target, wheels[0])
                for k in ("git", "ref", "file", "subdirectory", "hashes"):
                    entry.pop(k, None)
                entry["path"] = target
                entry["editable"] = False
            elif kind == "path":
                entry["path"] = local_path(entry["path"])
                if not keep_editable:
                    entry["editable"] = False
    return out


def local_package_paths(root, pipfile_lock):
    """The local packages inside the project, the source trees that
    Pipfile.lock names by a path in the project, by name. They are the
    project's outputs, and `publish` uploads them."""
    paths = {}
    for category in categories(pipfile_lock):
        for name, entry in pipfile_lock[category].items():
            path = entry.get("path")
            if path is not None and inside_project(path) and os.path.isdir(os.path.join(root, path)):
                paths[normalize(name)] = os.path.normpath(path)
    return paths


def distributions(directory):
    return [
        os.path.join(directory, n)
        for n in sorted(os.listdir(directory))
        if n.endswith((".whl", ".tar.gz", ".zip"))
    ]


def publish(root, lock_path, tool_lock, uv_publish_args, release=None):
    """Uploads with `uv publish` the `release` of the project, the sdists
    and wheels of its local packages that Nix built: built now, or the one
    at `release` that Nix built before. Pipenv has no upload command of its
    own. twine 6.2, the twine of nixpkgs, refuses metadata version 2.5,
    which current build backends such as hatchling write, and uv uploads
    them."""
    if release is None:
        check_purifier_lock(root, read_pipfile_lock(tool_lock), lock_path, tool_lock)
        log("building the release with Nix")
        release = nix_build(root, "release", lock_path, tool_lock)
    log(f"publishing files Nix built in {release}")
    files = distributions(release)
    if not files:
        raise Error("there is nothing to upload")
    result = subprocess.run(["uv", "publish", *uv_publish_args, *files], cwd=root, check=False)
    if result.returncode != 0:
        raise Error("uv publish failed")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="pipenv-purifier", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    lock_parser = sub.add_parser("lock", help=f"write {LOCK_FILE} beside Pipfile.lock")
    lock_parser.add_argument("--project", default=".", help="the directory that holds the Pipfile")
    lock_parser.add_argument(
        "--python",
        default=os.environ.get("PIPENV_PURIFIER_PYTHON", sys.executable),
        help="the Python that runs the build backends and Pipenv's resolver",
    )
    update_parser = sub.add_parser(
        "update",
        help="re-resolve Pipfile.lock with Pipenv, every package or the ones named, then write the lockfile",
    )
    update_parser.add_argument("--project", default=".", help="the directory that holds the Pipfile")
    update_parser.add_argument(
        "--python",
        default=os.environ.get("PIPENV_PURIFIER_PYTHON", sys.executable),
        help="the Python that runs the build backends and Pipenv's resolver",
    )
    update_parser.add_argument("packages", nargs="*", help="the packages to update (every package when absent)")
    prefetch_parser = sub.add_parser(
        "prefetch",
        help="fetch everything the development loop needs into the Nix store and install the project's .venv from it, offline",
    )
    prefetch_parser.add_argument("--project", default=".", help="the directory that holds the Pipfile")
    prefetch_parser.add_argument(
        "--inputs",
        help="the inputs Nix built for the project (the `prefetch` attribute of pkgs/cli/cli.nix); built with Nix when absent",
    )
    prefetch_parser.add_argument(
        "--categories",
        nargs="+",
        help="the package categories to install (default: `default` and `develop`, as `pipenv sync --dev`)",
    )
    publish_parser = sub.add_parser("publish", help="upload with `uv publish` the release that Nix builds")
    publish_parser.add_argument("--project", default=".", help="the directory that holds the Pipfile")
    publish_parser.add_argument(
        "--release",
        help="the `release` that buildPipenvProject built before, to upload instead of building it",
    )
    publish_parser.add_argument("uv_publish_args", nargs=argparse.REMAINDER, help="arguments for `uv publish`, after `--`")
    for sub_parser in (lock_parser, update_parser):
        sub_parser.add_argument("--input", action="append", help="a Nix producer exposing projections.python")
    for sub_parser in (lock_parser, update_parser, prefetch_parser, publish_parser):
        sub_parser.add_argument(
            "--lockfile",
            default=os.environ.get("PIPENV_PURIFIER_LOCKFILE"),
            help=f"the pipenv-purifier lockfile of an external build (default: $PIPENV_PURIFIER_LOCKFILE, else {LOCK_FILE} in the project)",
        )
        sub_parser.add_argument(
            "--tool-lockfile",
            default=os.environ.get("PIPENV_PURIFIER_TOOL_LOCKFILE"),
            help="the Pipfile.lock of an external build, which `lock` and `update` write instead of the one in the project "
            "(default: $PIPENV_PURIFIER_TOOL_LOCKFILE, else Pipfile.lock in the project)",
        )
    args = parser.parse_args(argv)
    root = os.path.abspath(args.project)
    lock_path = os.path.abspath(args.lockfile) if args.lockfile else os.path.join(root, LOCK_FILE)
    tool_lock = os.path.abspath(args.tool_lockfile) if args.tool_lockfile else os.path.join(root, "Pipfile.lock")
    try:
        if args.command == "lock":
            lock(root, args.python, lock_path, tool_lock, args.input)
        elif args.command == "update":
            update(root, args.python, lock_path, tool_lock, args.packages, args.input)
        elif args.command == "prefetch":
            prefetch(root, lock_path, tool_lock, args.inputs, args.categories)
        elif args.command == "publish":
            extra = args.uv_publish_args
            if extra and extra[0] == "--":
                extra = extra[1:]
            publish(root, lock_path, tool_lock, extra, args.release)
    except Error as e:
        log(str(e))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
