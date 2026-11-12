# SPDX-License-Identifier: MIT
#
# The default package overlay, which the flake exports as
# `overlays.default`. It adds one attribute to the package set, the scope
# `pkgs.pipenv-purifier`, which lib.makeScope makes. The scope holds the
# command `cli` (pkgs/cli) and the builder `buildPipenvProject`
# (pkgs/build-pipenv-project/default.nix), each a package of the scope's
# callPackage. A package takes the builder as
# `{ pipenv-purifier }: (pipenv-purifier.buildPipenvProject { src = ./.; }).packages.app`.
# `pipenv-purifier.overrideScope` replaces what the scope shares, and
# `pipenv-purifier.buildPipenvProject.override` replaces what the builder
# takes. A consumer that lists this flake in `projects` holds the overlay as
# `pipenv-purifier/default`, which its package sets apply by default.
#
# Both take the shared purifier library from this flake's closure: the
# builder its functions, and the CLI its source, which the CLI's own Nix
# builds import.
{ closure-lib, closure-inputs, ... }:
{
  overlay = final: prev: {
    pipenv-purifier = final.lib.makeScope final.newScope (self: {
      cli = self.callPackage ../../pkgs/cli { purifierSource = closure-inputs.purifier; };
      buildPipenvProject = self.callPackage ../../pkgs/build-pipenv-project/default.nix {
        inherit (closure-lib) purifier;
      };
    });
  };
}
