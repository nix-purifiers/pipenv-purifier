# SPDX-License-Identifier: MIT
#
# The `pipenv-purifier` command. It runs with the Pipenv of this package set,
# which is also the Pipenv that buildPipenvProject runs, so the build
# requirements that `pipenv-purifier lock` resolves are resolved by the Pipenv
# that installs from them. `prefetch` and `publish` build with the Nix library
# and the nixpkgs of this package set, and `publish` uploads with uv.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  python3,
  pipenv,
  uv,
  git,
  nix-prefetch-git,
  path,
  # The source of the shared purifier library.
  purifierSource,
}:
let
  # The lock run reads requirements with `packaging` and builds the local
  # packages with `build` to record their outputs.
  python = python3.withPackages (ps: [
    ps.packaging
    ps.build
    (ps.toPythonModule pipenv)
  ]);
in
stdenvNoCC.mkDerivation {
  pname = "pipenv-purifier";
  version = import ../version.nix;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../src
      ../../nix/lib
    ];
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/share/pipenv-purifier
    cp src/*.py $out/share/pipenv-purifier/
    cp -r nix/lib $out/share/pipenv-purifier/nix-lib
    makeWrapper ${python.interpreter} $out/bin/pipenv \
      --add-flags "-I $out/share/pipenv-purifier/nix-lib/pipenv_runtime.py" \
      --set PIPENV_PURIFIER_NIX_LIB $out/share/pipenv-purifier/nix-lib \
      --set PIPENV_PURIFIER_NIXPKGS ${path} \
      --set PIPENV_PURIFIER_LIBRARY ${purifierSource} \
      --prefix PATH : ${lib.makeBinPath [ pipenv ]}
    makeWrapper ${python.interpreter} $out/bin/pipenv-purifier \
      --add-flags "-I $out/share/pipenv-purifier/pipenv_purifier.py" \
      --prefix PATH : ${
        lib.makeBinPath [
          pipenv
          uv
          git
          nix-prefetch-git
        ]
      } \
      --prefix PATH : "$out/bin" \
      --set PIPENV_PURIFIER_INTERNAL 1 \
      --set-default PIPENV_PURIFIER_PYTHON ${python3.interpreter} \
      --set PIPENV_PURIFIER_NIX_LIB $out/share/pipenv-purifier/nix-lib \
      --set PIPENV_PURIFIER_NIXPKGS ${path} \
      --set PIPENV_PURIFIER_LIBRARY ${purifierSource}
    runHook postInstall
  '';

  meta = {
    description = "Lock, install and publish Pipenv projects that Nix builds";
    license = lib.licenses.mit;
    mainProgram = "pipenv-purifier";
  };
}
