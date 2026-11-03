# pipenv-purifier

pipenv-purifier keeps Pipenv's development workflow on locked,
Nix-resolved dependencies. Use the normal build and test commands in your
working tree; building the project itself in the Nix sandbox is an
optional next step.

Pipfile.lock pins every package with the hashes of all of its files.
`pipenv-purifier lock` adds what a sandboxed build also needs, in
`pipenv-purifier.lock.json` beside Pipfile.lock: the URLs of those files,
the build requirements of the packages that have to be built (local
packages, git checkouts and sdists), the content hash of each git checkout,
and the names of what the local packages produce. Pipenv itself installs
the project, in the Nix sandbox and on your machine, from the locked files.

## Quickstart

From the project root:

```zsh
nix shell 'github:nix-purifiers/pipenv-purifier'
pipenv-purifier lock
pipenv-purifier prefetch
. .venv/bin/activate
pytest
```

`prefetch` creates and installs the project’s `.venv` from the locked
dependencies. The activation command makes it available to your shell.

Commit the lockfiles that the lock command writes, including the build
tool's own lockfile when it has one. Keep using the project's usual build,
test and editor commands with this setup. Nix provides the locked
dependencies; the development commands above run outside the Nix sandbox.
No project Nix files are needed for this workflow.

Sandboxed builds of the whole project are an optional
[next step](#building-the-project-with-nix).

For persistent use, add these packages through your usual Nix configuration.


## Development loop

The development loop is Pipenv's own: `pipenv run`, `pipenv shell`, and the
tests in the `.venv` that `prefetch` installed. Local packages stay editable
when Pipfile.lock says so, so an edit to the source shows at once.

To add a dependency, run `pipenv install <package>`, then `pipenv-purifier
lock`, then `pipenv-purifier prefetch`. Run `pipenv-purifier lock` again
whenever the Pipfile, Pipfile.lock or the `pyproject.toml` of a local
package changes. The Nix build and `prefetch` refuse a lockfile that no
longer matches them.

To update dependencies, run `pipenv-purifier update`, which re-resolves
every package with `pipenv lock`, or `pipenv-purifier update <package>...`,
which re-resolves the named ones with `pipenv upgrade`. It then relocks
`pipenv-purifier.lock.json` against the new Pipfile.lock.

To publish, run `pipenv-purifier publish -- <arguments of uv publish>`.
Nix builds the `release`, the sdists and wheels of the local packages, and
`uv publish` uploads them, because Pipenv has no upload command of its own.
`--release <path>` uploads a release that Nix built before.

Pipenv has no plugin mechanism, so `pipenv-purifier` is a command of its own
that runs Pipenv, rather than a plugin that Pipenv loads.

`pipenv-purifier lock` keeps Pipfile.lock as Pipenv resolved it. When
Pipfile.lock is missing or no longer matches the Pipfile, `lock` writes it
with `pipenv lock` first. It looks up the URL of every hash of Pipfile.lock
on the package's index, for every platform. It reads the build requirements
of each package that may have to be built through the build backend's PEP
517 hooks, and resolves each set with `pipenv lock` on a throwaway Pipfile,
at the versions Pipfile.lock pins wherever the set allows them. It fetches
each git dependency at its locked commit and records the version that its
backend reads from git. It builds each local package once, to record the
names of its sdist and wheel and the scripts it installs. `--lockfile <path>` writes the lockfile somewhere else, and every other command takes
the same option.

## Dependencies from another purified project

```zsh
nix shell 'github:nix-purifiers/pipenv-purifier'
pipenv-purifier lock \
  --input 'github:owner/library/<rev>#library'
pipenv-purifier prefetch
pipenv sync
pipenv run test
```

The producer exposes `projections.python`, the wheelhouse format shared with
uv, PDM, pip and Poetry. Repeat `--input` for more producers. Project
requirements stay unchanged; the purifier lock records the Nix source pins
and omits supplied downloads. Relocking retains those pins; `update`
refreshes them.

Use the `pipenv` wrapper supplied by this shell for sync, install and run.
It validates the lock and rebinds input paths in a temporary native lockfile.
Committed files stay unchanged. Without a lockfile, it warns and uses
ordinary, impure Pipenv resolution. Lock and update dependencies with
`pipenv-purifier lock` and `pipenv-purifier update`.

The builder exposes `projections.python` on each local package and on the
project. Exported wheels include their native runtime closure, with
Nix-derived versions and dependency metadata for ordinary installers.
Composed publishing uploads those wheels. Use an index accepting local
versions, or consume the repository with `--find-links`.

## Building the project with Nix

Once the native development workflow is working, you can also build and
test the whole project in the Nix sandbox. For this step, keep a flake or
another Nix build definition in the project's repository, or maintain an
external packaging repository that points at its sources and lockfiles.
The builder consumes the same lockfiles as the development workflow.

The expression applies this flake's `overlays.default`, which adds the
scope `pipenv-purifier` to the package set. The scope holds the builder
`buildPipenvProject` and the command.

A project whose authors want a flake that packages it can add one, in the
project's repository or in another one. The flake calls the builder
directly:

```nix
{
  inputs.pipenv-purifier.url =
    "github:nix-purifiers/pipenv-purifier";
  inputs.nixpkgs.follows = "pipenv-purifier/nixpkgs";

  outputs =
    { nixpkgs, pipenv-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ pipenv-purifier.overlays.default ];
      };
      project =
        pkgs.pipenv-purifier.buildPipenvProject {
        src = ./.;
      };
    in
    {
      # The sdist and wheel of the local package `app`.
      packages.${system}.app = project.packages.app;
      # A virtual environment with the packages of the
      # `default` category.
      packages.${system}.environment =
        project.environment;
      # The Pipfile's script `test`, run in the sandbox.
      checks.${system}.tests = project.tests;
      # The script `app`, for `nix run`.
      apps.${system}.default = {
        type = "app";
        program = pkgs.lib.getExe project.programs.app;
      };
    };
}
```

`buildPipenvProject` is a package for `callPackage`. It takes the packages
it needs by name, such as `stdenvNoCC`, `pipenv` and `fetchurl`.
`pipenv-purifier.buildPipenvProject.override` replaces any of them, and
`pipenv-purifier.overrideScope` replaces what the scope shares.

`buildPipenvProject` gives:

- `packages.<name>`: for each local package of the project, a package that
  Pipfile.lock names by a path of a directory inside the project, its sdist
  and wheel. Its `artifacts` attribute names the files without building
  them: `artifacts.sdist`, `artifacts.wheel`, and each file by its name,
  such as `artifacts."app-1.0.0.tar.gz"`.
- `tests`: the Pipfile's script `test` (under `[scripts]`), run by the shell
  in the sandbox, in a writable copy of an environment with the packages of
  every category.
- `release`: the sdists and wheels of every local package in one directory,
  which `pipenv-purifier publish` uploads.
- `fetches`: every download of the lock, as entries of the shared
  [purifier](https://github.com/nix-purifiers/purifier) library. A wheel for
  some systems only carries them in `systems`.
- `environment`: a virtual environment with the packages of `categories`,
  installed by `pipenv sync`, with their scripts in `bin/`.
- `programs.<script>`: each script of the local packages, from
  `environment`, as a package with `meta.mainProgram`.
- `prefetch`: what `pipenv-purifier prefetch` installs the `.venv` from.

Every attribute name comes from the lockfiles, so Nix knows them without
building anything.

`buildPipenvProject` takes these arguments:

- `src`: the project root, which holds the Pipfile and Pipfile.lock.
- `lockFile`: the lockfile, by default `src + "/pipenv-purifier.lock.json"`.
  It may lie outside `src`, as in a flake that packages a project without
  changing it.
- `fetchers`: replacements for the fetchers of nixpkgs, which the purifier
  library's `fetchEntry` takes. A `fetchurl` that sends credentials or reads
  a company mirror goes here.
- `categories`: the package categories `environment` installs, as `pipenv
  sync --categories`. The default is `[ "default" ]`.
- `testScript` and `testCategories`: the script `tests` runs, by default
  `"test"`, and the categories it runs with, by default all of them.
- `python`: the interpreter. The default is nixpkgs' `pythonXY` for the
  `python_version` in the Pipfile's `[requires]`, or `python3`.
- `pathSources`: the local packages that Pipfile.lock names by a path
  outside `src`, such as `"../shared"`, each mapped to a Nix path.

`pipenv-purifier.lib.pipenv-purifier.readLock { src, lockFile }` reads the
two lockfiles into the lock in memory of the contract, `{ purifier,
entries, outputs, problems }`, for a tool such as an SBOM generator.

### One-off builds without a project Nix file

For an ad hoc build, the builder can also be evaluated directly from the
project root. Replace the example package name with one from your project:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/pipenv-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.pipenv-purifier.buildPipenvProject { src = ./.; })
.packages.app'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

## Working offline

`pipenv-purifier prefetch` realizes in the Nix store the Python of the
build and the locked files of every category for this system, development
and test packages included, with the wheels of the packages from git. It
keeps them alive with a garbage-collector root at
`.pipenv-purifier/inputs` in the project, which belongs in `.gitignore`.
Then it runs `pipenv sync --dev` into `.venv` with pip reading those files
alone. `--categories` picks other categories.

After a prefetch, `pipenv run`, `pipenv shell`, the tests and the editor
work with the network cut off. `pipenv install`, `pipenv lock` and
`pipenv-purifier update` resolve against the index, so they need the
network.

## Editor

An editor for Python needs the interpreter of the `.venv`, with the
project's packages in it. Point the editor's Python at `.venv/bin/python`,
or let it find `.venv` in the project, as Pyright and the Python extension
of VS Code do. A Python editor reads the project's packages from the
`.venv`, which `prefetch` installs, and asks for no downloads of its own,
so `prefetch` fetches nothing for the editor beyond the `.venv`. The
language server comes from the editor's installation.

## Troubleshooting

| Error | Fix |
| --- | --- |
| `Pipfile.lock does not match the Pipfile`, from `prefetch` | Run `pipenv-purifier lock`, which runs `pipenv lock` first. |
| `pipenv-purifier.lock.json no longer matches Pipfile.lock` | Run `pipenv-purifier lock`. This follows a `pipenv install`. |
| `... was edited after pipenv-purifier lock wrote it` | Run `pipenv-purifier lock`. The lockfile's `contentHash` no longer matches its content. |
| `... does not agree with Pipfile.lock: it has no files of <package>` | Run `pipenv-purifier lock`. |
| `... is not a lockfile of this pipenv-purifier` or `has lock format version` | Run `pipenv-purifier lock` with this version of pipenv-purifier. |
| `has no pipenv-purifier.lock.json` | Run `pipenv-purifier lock`. |
| `... failed 3 times ...` during a lock | Check the network, and run `pipenv-purifier lock` again. |
| `the Pipfile has no script test` | Add `test` under `[scripts]`, or pass `testScript`. |
| `Pipfile.lock names the local path ../x, which is outside src` | Pass it in `pathSources`. |

## Supported language repositories

pipenv-purifier reads these sources of packages:

- Package indexes that the Pipfile's `[[source]]` tables name, through
  their JSON (PEP 691) or HTML (PEP 503) pages. An index that needs
  credentials gets a `fetchurl` in `fetchers` that supplies them, and the
  lockfile records URLs without them.
- Git repositories, at the commit Pipfile.lock pins, with submodules and
  with `subdirectory`. A backend that reads its version from git, such as
  setuptools-scm or hatch-vcs, gets the version the lock run read.
- URLs of a wheel, an sdist or a source archive.
- Local directories, sdists and wheels, editable or not, inside the project
  or, through `pathSources`, outside it.

It reads every package category, `default`, `develop` and custom ones.

`lock` stops with an error on these:

- A git reference that is not a commit. Run `pipenv lock` again.
- A build requirement that names a URL. Build requirements come from an
  index.
- A URL in Pipfile.lock with credentials in it.
- A hash of an algorithm other than sha256.

The builds run on Linux, x86_64 and aarch64, and on aarch64-darwin. pip
skips a package whose markers exclude the build's system. A package that
the markers include, with neither a wheel for the build's system nor an
sdist, fails the build with pip's error about the missing file.

## Examples

For day-to-day work on these projects, use the native-tool setup and
commands in [Quickstart](#quickstart) and [Development loop](#development-loop).
The Nix expressions below show optional sandboxed packaging of those
projects.

[Pipenv](https://github.com/pypa/pipenv) develops itself with a Pipfile, so
its repository is a Pipenv project like any other. A developer of Pipenv
works on a clone of it as the Quickstart shows:

```zsh
nix shell 'github:nix-purifiers/pipenv-purifier'
git clone https://github.com/pypa/pipenv
cd pipenv
pipenv-purifier lock
pipenv-purifier prefetch
pipenv run pytest tests/unit
```

A flake can also package Pipenv with the lockfile kept in the flake. In a
clone of the revision the flake builds, `--lockfile` writes the lockfile
into the flake:

```zsh
nix shell 'github:nix-purifiers/pipenv-purifier'
cd pipenv
pipenv-purifier lock \
  --lockfile ../pipenv-packaging/pipenv-purifier.lock.json
```

The flake in `pipenv-packaging/` takes the repository as an input and
builds it from that lockfile:

```nix
{
  inputs.pipenv-purifier.url =
    "github:nix-purifiers/pipenv-purifier";
  inputs.nixpkgs.follows = "pipenv-purifier/nixpkgs";
  inputs.pipenv-src = {
    url = "github:pypa/pipenv";
    flake = false;
  };

  outputs =
    {
      nixpkgs,
      pipenv-purifier,
      pipenv-src,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ pipenv-purifier.overlays.default ];
      };
      project =
        pkgs.pipenv-purifier.buildPipenvProject {
        src = pipenv-src;
        lockFile = ./pipenv-purifier.lock.json;
        categories = [
          "default"
          "develop"
        ];
      };
    in
    {
      # A virtual environment with the dependencies of
      # Pipenv and its
      # development tools.
      packages.${system}.environment =
        project.environment;
    };
}
```

Pipenv's Pipfile names its dependencies, and Pipenv itself is the project
around them, so `project.packages` is empty for this repository. A project
whose Pipfile lists itself, as with `app = { path = ".", editable = true }`,
gets its sdist and wheel as `project.packages.app`.

When the flake moves `pipenv-src` to another revision, run the same `lock
--lockfile` command in a clone of that revision.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).
