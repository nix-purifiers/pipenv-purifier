# Design

## Two lockfiles

Pipfile.lock pins every package of every category with the SHA-256 hashes
of all of the release's files, for every platform. It names packages from git
by repository and commit, packages from a URL by the URL, and local packages
by path. It records no URL of a file from an index, no build requirement,
and nothing about what the local packages produce. The Nix library reads
Pipfile.lock with `builtins.fromJSON` (`lib-overlays/default/lock.nix`).

`pipenv-purifier lock` (`src/pipenv_purifier.py`) writes
`pipenv-purifier.lock.json`, format version 2, with only what Pipfile.lock
cannot record:

- `urls`: the URL of each file of an index, keyed by the sha256 that
  Pipfile.lock, or `buildPackages`, lists for the file. The file name is the
  percent-decoded last segment of the URL, and the lock run refuses an
  index that serves a file under a URL that names another file.
- `buildPackages`: for each package that only build requirements need,
  `"<name>==<version>"`, the sha256 hashes of its files, which Pipfile.lock
  does not have.
- `buildRequirements`: each distinct set of build requirements, with the
  keys of the packages `pipenv lock` resolved it to. A set that did not
  resolve has `error` instead, and the Nix build reports it only if it has
  to build a package that needs it.
- `builds`: for each package that may be built, the index of its set.
- `sources`: for each package from git, the NAR `hash` that
  `nix-prefetch-git` reports for its checkout and the `version` its backend
  read from the repository. For a package from a URL that Pipfile.lock lists
  no hash for, the `hash` of the file. Pipfile.lock has the URL and commit.
- `outputs`: for each local package inside the project, the names of its
  sdist and wheel, and its scripts. The version and whether the wheel is the
  same on every system come from the wheel's name, and the path from
  Pipfile.lock.
- `inputsHash`: a hash over Pipfile.lock and the `pyproject.toml` of every
  local package inside the project. The Nix library computes the same hash
  and refuses the lockfile when they differ.
- `contentHash`: the SHA-256 of the lockfile's JSON without this field,
  with sorted keys and no whitespace, which is the text that
  `builtins.toJSON` writes. The Nix library refuses an edited lockfile.

A set of build requirements resolves at the versions Pipfile.lock pins
wherever the set allows them. A package of the set that Pipfile.lock pins
at another version is pinned in the throwaway Pipfile, and the set is
resolved again. When the set does not allow the pinned version, the set
keeps its own, and the lock run says so.

## The lock in memory

`lib-overlays/default/lock.nix`, published as `lib.pipenv-purifier.readLock`, reads both
lockfiles into the shape of the purifier contract: `purifier`, `entries`
(the download entries of the shared library, a wheel for some platforms
with its `systems`), `outputs` and `problems`. It builds the file entries
from `urls` and the hashes of Pipfile.lock, and the git entries from the
commit of Pipfile.lock and the hash of `sources`. The checkout needs no
`.git`, because the build makes a wheel of it, so `leaveDotGit` is false
and `commitObject` null. `problems` names the first thing wrong, in the
order missing file, missing fields, format version, `contentHash`,
`inputsHash`, then a URL for a hash that no lockfile lists or a package
without files. The builder passes the result to the library's `checkLock`,
and takes the files of its system with `entriesFor`. The builder reads the
derived shapes from the result's `views`.

## The lock run

1. `pipenv verify` checks that Pipfile.lock matches the Pipfile. When
   Pipfile.lock is missing or does not match, `pipenv lock` writes it, and
   otherwise Pipfile.lock stays as it is.
2. For each package of an index, the tool reads the package's page on its
   index, as JSON (PEP 691) or HTML (PEP 503), and records the URLs of the
   files whose SHA-256 Pipfile.lock lists. The URLs carry no credentials.
3. For each package that may have to be built on some system (an sdist and
   no wheel tagged `none-any`), each local package, git checkout and source
   archive, the tool reads the static build requirements of the source
   tree's `[build-system]` table and asks the backend for the requirements
   it adds, through the PEP 517 hooks `get_requires_for_build_sdist`,
   `get_requires_for_build_wheel` and `get_requires_for_build_editable`.
4. It resolves each distinct set with `pipenv lock` on a throwaway Pipfile
   that reads the project's indexes, at the versions of Pipfile.lock, then
   reads the files of the resolved packages as in step 2, and repeats step
   3 for those that may have to be built.
5. It builds each local package inside the project with `python -m build`
   and records its outputs.

## Choosing the files for a system

The shared [purifier](https://github.com/nix-purifiers/purifier) library's
`wheels` decides from a wheel's file name whether it installs with the
build's Python on the build's system (PEP 425 tags, manylinux 1, 2010, 2014
and `2_N` against the glibc of the package set, `macosx` up to the package
set's oldest macOS, `abi3`). For each package,
`pkgs/build-pipenv-project/default.nix` takes its wheels that install, or else
its sdist and the build of it. A build adds the files of its set of build
requirements, chosen the same way, and the builds those need in turn. The
library's `fetchEntry` fetches every chosen file and every git checkout, and
the files are linked into one flat directory, the wheelhouse.

## Installing in the sandbox

pip runs with `PIP_NO_INDEX` and `PIP_FIND_LINKS` pointing at the
wheelhouse, so it reads nothing else, and its build isolation installs build
requirements from the wheelhouse too.

The build rewrites a copy of Pipfile.lock: a package from a URL becomes a
path to its locked file, a package from git a path to its wheel, and a local
package a path into the build's copy of the project, or into the build's copy
of what `pathSources` gives for a path outside it. Each installs as a copy,
because the result outlives the build directory. Pipenv then runs `pipenv
sync --categories ...` with `PIPENV_PIPFILE` pointing at the copy and
`VIRTUAL_ENV` at the output, a virtual environment of the build's Python.

A package from git builds into a wheel in a derivation of its own, with
`SETUPTOOLS_SCM_PRETEND_VERSION` set to the version the lock run read from
the repository. The locked checkout has no `.git`, and setuptools-scm, which
hatch-vcs uses, cannot apply its per-distribution variable before it knows
the distribution's name, so the variable has to apply to that build alone.

A local package's sdist and wheel come from `python -m build`, which builds
in an isolated environment that pip fills from the wheelhouse. The build
checks that it made the files the lockfile names.

## PYTHONPATH

The setup hook of nixpkgs' Python puts the site-packages of the Python
packages among the build inputs on PYTHONPATH, and Pipenv is one of those
inputs. pip takes a package on PYTHONPATH as installed, so it would leave
the locked copy out of the environment, and an isolated build would import
it ahead of the locked build requirements. Every build of the builder
unsets PYTHONPATH after its `preBuild` hook, and `prefetch` leaves it out
of the environment of `pipenv sync`. Pipenv's wrapper sets the path that
Pipenv itself needs.

## The commands

`update` runs `pipenv lock`, or `pipenv upgrade <package>...` for named
packages, which writes Pipfile.lock and installs nothing, and then the lock
run. `prefetch` builds the `prefetch` attribute of `pkgs/cli/cli.nix` with
`nix-build --out-link .pipenv-purifier/inputs`, which makes the link a
garbage-collector root, and installs `.venv` from it as the build installs
its environment, with editable local packages kept editable. `publish`
builds the `release` and uploads its files with `uv publish`. Every command
checks Pipfile.lock and the lockfile before it builds, so its error names
the file and the command to run, and every command takes `--lockfile`.

## The interpreter

The Python comes from nixpkgs: `pythonXY` for the Pipfile's
`python_version`, or the `python` argument. Pipenv never downloads one.
