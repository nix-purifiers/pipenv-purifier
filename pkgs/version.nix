# SPDX-License-Identifier: MIT
# Source builds identify their contents, rather than claiming a release version.
let
  source = builtins.path {
    path = ../.;
    name = "pipenv-purifier-source";
    filter = path: _: builtins.baseNameOf path != ".git";
  };
in
"0.0.0-dev.${builtins.substring 0 12 (builtins.baseNameOf source)}"
