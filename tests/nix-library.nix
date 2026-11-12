# SPDX-License-Identifier: MIT
#
# Unit tests of the Nix library that need no build: wheel selection, name
# normalization, file names from URLs, and the reading of the committed
# lockfiles. The conformance checks cover the lockfiles it refuses.
{
  pkgs,
  # The shared purifier library, for its wheel selection.
  purifier,
}:
let
  inherit (pkgs) lib;

  installs = purifier.wheels {
    pythonVersion = "3.14";
    arch = "x86_64";
    glibcVersion = "2.40";
  };

  wheelCases = {
    pure = installs "attrs-25.3.0-py3-none-any.whl";
    pythonTwoAndThree = installs "six-1.17.0-py2.py3-none-any.whl";
    sameCpython = installs "pydantic_core-2.41.4-cp314-cp314-manylinux_2_17_x86_64.manylinux2014_x86_64.whl";
    otherCpython = installs "pydantic_core-2.41.4-cp313-cp313-manylinux_2_17_x86_64.manylinux2014_x86_64.whl";
    stableAbi = installs "cryptography-46.0.3-cp311-abi3-manylinux_2_34_x86_64.whl";
    stableAbiNewerThanPython = installs "cryptography-46.0.3-cp315-abi3-manylinux_2_34_x86_64.whl";
    newerGlibc = installs "numpy-2.3.4-cp314-cp314-manylinux_2_41_x86_64.whl";
    otherArch = installs "numpy-2.3.4-cp314-cp314-manylinux_2_28_aarch64.whl";
    musl = installs "numpy-2.3.4-cp314-cp314-musllinux_1_2_x86_64.whl";
    macos = installs "numpy-2.3.4-cp314-cp314-macosx_14_0_arm64.whl";
    windows = installs "pywin32-311-cp314-cp314-win_amd64.whl";
    buildTag = installs "example-1.0-1-py3-none-any.whl";
    pythonTwoOnly = installs "example-1.0-py2-none-any.whl";
  };

  wheelExpected = {
    pure = true;
    pythonTwoAndThree = true;
    sameCpython = true;
    otherCpython = false;
    stableAbi = true;
    stableAbiNewerThanPython = false;
    newerGlibc = false;
    otherArch = false;
    musl = false;
    macos = false;
    windows = false;
    buildTag = true;
    pythonTwoOnly = false;
  };

  simpleLock = import ../lib-overlays/default/lock.nix { src = ./fixtures/simple; };
  current = simpleLock.views;

  normalizeCases = {
    "Foo.Bar_baz" = "foo-bar-baz";
    "zope.interface" = "zope-interface";
    "attrs" = "attrs";
    "Django--REST" = "django-rest";
  };

  pathCases = {
    "." = "";
    "./" = "";
    "./libs/greeting" = "libs/greeting";
    "libs/greeting/" = "libs/greeting";
  };

  # File names from URLs, as the lock tool reads them.
  fileNameCases = {
    "https://files.example/packages/ab/torch-2.0.0%2Bcpu-cp314-cp314-linux_x86_64.whl" =
      "torch-2.0.0+cpu-cp314-cp314-linux_x86_64.whl";
    "https://x.example/a/six-1.17.0.tar.gz?x=1#sha256=ab" = "six-1.17.0.tar.gz";
  };

  # The committed lockfile of every fixture passes checkLock of the shared
  # purifier library, the shape and the problems both. The lock tool wrote
  # it, so its contentHash is the hash the lock tool computes, and the
  # library computes the same.
  checks = lock: builtins.tryEval (builtins.deepSeq (purifier.checkLock lock).entries true);
  currentLock = checks simpleLock;
  sourcesLock = checks (import ../lib-overlays/default/lock.nix { src = ./fixtures/sources; });
  # A wheel for one platform carries the systems it installs on.
  systemsOf =
    name: (lib.findFirst (entry: entry.path == name) { } simpleLock.entries).systems or "everywhere";
  systemCases = {
    "attrs-25.3.0-py3-none-any.whl" = "everywhere";
    "markupsafe-3.0.3-cp314-cp314-manylinux2014_aarch64.manylinux_2_17_aarch64.manylinux_2_28_aarch64.whl" =
      [ "aarch64-linux" ];
    "markupsafe-3.0.3-cp314-cp314-win_amd64.whl" = [ ];
  };

  failures =
    lib.filter (name: wheelCases.${name} != wheelExpected.${name}) (lib.attrNames wheelCases)
    ++ lib.concatMap (
      name: lib.optional (current.normalize name != normalizeCases.${name}) "normalize ${name}"
    ) (lib.attrNames normalizeCases)
    ++ lib.concatMap (
      path: lib.optional (current.normalizePath path != pathCases.${path}) "normalizePath ${path}"
    ) (lib.attrNames pathCases)
    ++ lib.concatMap (
      url: lib.optional (current.fileName url != fileNameCases.${url}) "fileName ${url}"
    ) (lib.attrNames fileNameCases)
    ++ lib.optional (!currentLock.success) "the simple fixture's pipenv-purifier.lock.json was refused"
    ++ lib.optional (!sourcesLock.success) "the sources fixture's pipenv-purifier.lock.json was refused"
    ++ lib.concatMap (name: lib.optional (systemsOf name != systemCases.${name}) "systems of ${name}") (
      lib.attrNames systemCases
    );
in
pkgs.runCommand "pipenv-purifier-test-nix-library" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      echo "failed: "${lib.escapeShellArg (lib.concatStringsSep ", " failures)} >&2
      exit 1
    ''
)
