# SPDX-License-Identifier: MIT
#
# What the `pipenv-purifier` command builds for a project directory and a
# lockfile, both given as absolute paths, with the nixpkgs the command was
# built with: the `prefetch` or the `release` of buildPipenvProject.
#
# A local package that Pipfile.lock names by a path outside the project is
# read from that path.
{
  nixpkgs,
  # The source of the shared purifier library.
  purifier,
  src,
  lockFile,
  pipfileLock,
  attribute,
}:
let
  pkgs = import nixpkgs { };
  inherit (pkgs) lib;

  # A directory without what Pipenv, Python and git leave in it.
  source =
    path:
    builtins.path {
      inherit path;
      name = "source";
      filter =
        p: type:
        !builtins.elem (baseNameOf p) [
          ".git"
          ".venv"
          ".pipenv-purifier"
          "build"
          "__pycache__"
          "dist"
        ];
    };

  root = /. + src;
  pipfileLockData = builtins.fromJSON (builtins.readFile (/. + pipfileLock));
  localPaths = lib.concatMap (
    category:
    lib.concatMap (entry: lib.optional (entry ? path) entry.path) (
      lib.attrValues pipfileLockData.${category}
    )
  ) (builtins.filter (k: k != "_meta") (lib.attrNames pipfileLockData));
  outside = builtins.filter (
    path: path == ".." || lib.hasPrefix "../" path || lib.hasPrefix "/" path
  ) localPaths;
  # Nix paths are normalized, so ".." in the string leaves the project.
  absolute = path: if lib.hasPrefix "/" path then /. + path else /. + "${src}/${path}";
  pathSources = lib.genAttrs outside (
    path:
    let
      target = absolute path;
    in
    if lib.pathIsDirectory target then source target else target
  );

  buildPipenvProject = pkgs.callPackage ../build-pipenv-project/default.nix {
    purifier = import "${purifier}/nix/lib" { inherit lib; };
  };
  project = buildPipenvProject {
    inherit pathSources;
    src = source root;
    lockFile = /. + lockFile;
    pipfileLock = /. + pipfileLock;
  };
in
if
  builtins.elem attribute [
    "prefetch"
    "release"
  ]
then
  if
    attribute == "release"
    && (builtins.fromJSON (builtins.readFile (/. + lockFile))).projectInputs or [ ] != [ ]
  then
    project.release.projections.python
  else
    project.${attribute}
else
  throw "pipenv-purifier: cli.nix builds `prefetch` or `release`, not ${attribute}"
