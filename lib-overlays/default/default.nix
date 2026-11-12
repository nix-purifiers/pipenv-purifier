# SPDX-License-Identifier: MIT
#
# The `pipenv-purifier` library namespace. It holds `readLock`
# (lib-overlays/default/lock.nix), which reads a project's lockfiles into the lock in
# memory of the purifier contract, for a tool such as an SBOM generator.
# The builder is the package `buildPipenvProject` of the scope
# `pipenv-purifier`, which the default package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    pipenv-purifier = (prev.pipenv-purifier or { }) // {
      readLock = import ./lock.nix;
    };
  };

}
