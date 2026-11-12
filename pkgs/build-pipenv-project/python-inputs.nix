# SPDX-License-Identifier: MIT
{
  lib,
  purifier,
  runCommand,
  writeText,
  python,
  system,
  lock,
  projectDependencies ? null,
}:
let
  dependencies =
    if projectDependencies == null then
      purifier.lockedProjectInputs {
        inputs = lock.projectInputs or [ ];
        inherit system;
      }
    else
      projectDependencies;
  supplied = purifier.projectInputs {
    inherit dependencies;
    formats = [ "python" ];
  };
  views = writeText "pipenv-python-views.json" (
    builtins.toJSON (
      map (input: {
        repository = toString input.repository;
        catalog = input.repository.catalog;
      }) supplied
    )
  );
  bindings =
    runCommand "pipenv-python-bindings"
      {
        nativeBuildInputs = [ (python.withPackages (ps: [ ps.packaging ])) ];
      }
      ''
        python ${./python_bindings.py} --tools ${purifier.projectInputsTool} \
          --views ${views} --old-repositories ${
            writeText "pipenv-old-repositories.json" (
              builtins.toJSON (map (input: input.nativeRepository) (lock.projectInputs or [ ]))
            )
          } \
          --destination "$out"
      '';
in
{
  inherit dependencies bindings;
}
