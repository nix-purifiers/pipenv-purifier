# SPDX-License-Identifier: MIT
#
# Builds a Pipenv project in the Nix sandbox from its two lockfiles.
#
# Pipfile.lock pins the project's packages with the hashes of their files,
# and pipenv-purifier.lock.json adds the URLs of those files, the build
# requirements of the packages that may have to be built, the locked
# checkouts and files of the packages from git and URLs, and the project's
# outputs. For the system and Python it builds with, this function picks the
# locked files the build needs: for each package, its wheels that install,
# or else its sdist and the build requirements that building it needs. It
# links them into one directory, the wheelhouse, and runs Pipenv with pip
# reading the wheelhouse and nothing else.
#
# The result has the attributes of the purifier contract:
# - `packages.<name>`: for each local package of the project, its sdist and
#   wheel. Its `artifacts` name each file, as the lockfile records them,
#   without building.
# - `tests`: the Pipfile's script `testScript`, run in the sandbox in an
#   environment of `testCategories`.
# - `release`: the sdists and wheels of every local package in one
#   directory, which is what `pipenv-purifier publish` uploads.
# - `fetches`: the `entries` of the lock in memory (nix/lib/lock.nix), the
#   download entries of the shared purifier library, each wheel for some
#   systems only with its `systems`.
# It also has:
# - `environment`: a virtual environment with the packages of `categories`
#   installed by `pipenv sync`, with their scripts in `bin/`.
# - `programs.<script>`: each script of the local packages, from
#   `environment`, as a package that `nix run` runs.
# - `prefetch`: what `pipenv-purifier prefetch` installs the project's .venv
#   from.
#
# The builder is a package for callPackage, which the flake's default
# package overlay adds to the scope `pipenv-purifier` of the package set.
# `pipenv-purifier.buildPipenvProject.override` replaces any of the packages
# it takes by name.
{
  lib,
  stdenvNoCC,
  linkFarm,
  runCommand,
  writeText,
  writeShellScriptBin,
  pipenv,
  glibc,
  fetchurl,
  fetchgit,
  unzip,
  zstd,
  # The Pythons of nixpkgs by attribute name, such as `python314`, and the
  # default Python.
  pythonInterpreters,
  python3,
  # The shared purifier library, `lib.purifier` of its flake.
  purifier,
}:
{
  # The project root, which holds the Pipfile.
  src,
  # Replacements for the fetchers of nixpkgs, which the shared purifier
  # library's fetchEntry takes, such as a `fetchurl` that sends credentials
  # or reads a company mirror.
  fetchers ? { },
  # The lockfile that `pipenv-purifier lock` wrote. It may lie outside
  # `src`, as in a flake that packages a project without changing it.
  lockFile ? src + "/pipenv-purifier.lock.json",
  # Pipfile.lock, by default the one in `src`. An external build may pass
  # its own copy, which the build uses in place of the one in `src`.
  pipfileLock ? src + "/Pipfile.lock",
  # The Python the project builds and runs with. The default is nixpkgs'
  # pythonXY for the `python_version` of the Pipfile's [requires], or
  # python3 when the Pipfile names none.
  python ? null,
  # The package categories `environment` installs, as `pipenv sync
  # --categories`.
  categories ? [ "default" ],
  # The script of the Pipfile's [scripts] that `tests` runs, and the package
  # categories it runs with.
  testScript ? "test",
  testCategories ? null,
  # The local packages that Pipfile.lock names by a path outside `src`, such
  # as "../shared", each mapped to a Nix path that holds it. A path inside
  # `src` is read from `src`.
  pathSources ? { },
  projectDependencies ? null,
}:
let
  inherit (builtins)
    concatMap
    elemAt
    filter
    genericClosure
    listToAttrs
    map
    ;

  # The lock in memory, which checkLock refuses with its problems.
  read = purifier.checkLock (
    import ./lock.nix {
      inherit src lockFile pipfileLock;
    }
  );
  lock = read.views;
  # The paths of the entries that this system needs.
  forSystem = listToAttrs (
    map (entry: {
      name = entry.path;
      value = null;
    }) (purifier.entriesFor stdenvNoCC.hostPlatform.system read)
  );
  # A download entry of the lockfile to its store path.
  # Pipfile.lock records packages from an index, from git and from URLs,
  # which the fetchers of files and git checkouts fetch. The other packages
  # are the ones fetchEntry builds with after a fetch.
  fetch = purifier.fetchEntry (
    {
      inherit
        fetchurl
        fetchgit
        runCommand
        unzip
        zstd
        python3
        writeText
        ;
    }
    // fetchers
  );

  pythonAttribute = "python${lib.replaceStrings [ "." ] [ "" ] lock.pythonVersion}";
  interpreter =
    if python != null then
      python
    else if lock.pythonVersion == null then
      python3
    else
      pythonInterpreters.${pythonAttribute}
        or (throw "pipenv-purifier: the Pipfile asks for Python ${lock.pythonVersion}, and nixpkgs has no ${pythonAttribute}. Pass `python`.");

  inputData = builtins.fromJSON (builtins.readFile lockFile);
  providedNames = inputData.projectInputNames or [ ];
  projectInputs = import ./python-inputs.nix {
    inherit
      lib
      purifier
      runCommand
      writeText
      projectDependencies
      ;
    python = interpreter;
    system = stdenvNoCC.hostPlatform.system;
    lock = inputData;
  };
  runtimePython = python3.withPackages (ps: [ (ps.toPythonModule pipenv) ]);
  runtimePipenv = writeShellScriptBin "pipenv" ''
    export PIPENV_PURIFIER_NIX_LIB=${./.}
    export PIPENV_PURIFIER_INTERNAL=1
    export PATH=${pipenv}/bin:$PATH
    exec ${runtimePython.interpreter} -I ${./pipenv_runtime.py} "$@"
  '';
  substituteProvided = lib.optionalString (projectInputs.dependencies != [ ]) ''
    ${interpreter.interpreter} ${./rebind_pipfile.py} \
      ${projectInputs.bindings}/inputs.json "$TMPDIR/pipfile/Pipfile.lock"
  '';

  platform = stdenvNoCC.hostPlatform;
  target = "Python ${interpreter.pythonVersion} on ${platform.system}";
  installs = purifier.wheels (
    {
      inherit (interpreter) pythonVersion;
    }
    // (
      if platform.isDarwin then
        {
          # macOS wheel tags name the CPU arm64, and a wheel installs when
          # the oldest macOS it runs on is at most nixpkgs' darwinMinVersion.
          arch = "arm64";
          macosVersion = platform.darwinMinVersion;
        }
      else
        {
          arch = platform.parsed.cpu.name;
          glibcVersion = glibc.version;
        }
    )
  );

  # What installing a locked package of an index needs on this system: its
  # wheels that install, or else its sdist and a build of it. A package with
  # neither is one whose markers leave it out on this system, as with a
  # package only for Windows; pip skips it by its markers, and when the
  # markers do include it, pip fails on the missing file with its own error.
  needs =
    key:
    let
      locked =
        lock.packages.${key}
          or (throw "pipenv-purifier: pipenv-purifier.lock.json has no files of ${key}. Run `pipenv-purifier lock`.");
      wheels = filter (wheel: forSystem ? ${wheel} && installs wheel) locked.wheels;
    in
    if wheels != [ ] then
      {
        files = wheels;
        builds = [ ];
      }
    else if locked.sdist != null then
      {
        files = [ locked.sdist ];
        builds = [ key ];
      }
    else
      {
        files = [ ];
        builds = [ ];
      };

  requirementSet =
    key:
    let
      set = elemAt lock.buildRequirements (
        lock.builds.${key}
          or (throw "pipenv-purifier: pipenv-purifier.lock.json has no build requirements for ${key}, which ${target} has to build. Run `pipenv-purifier lock`.")
      );
    in
    if set ? error then
      throw "pipenv-purifier: building ${key} with ${target} needs the build requirements ${lib.concatStringsSep ", " set.requires}, which `pipenv-purifier lock` could not resolve:\n${set.error}"
    else
      set;

  requirementNeeds = key: map needs (requirementSet key).packages;

  # The builds that some builds need, with the builds that their build
  # requirements need in turn.
  buildClosure =
    keys:
    map (item: item.key) (genericClosure {
      startSet = map (key: { inherit key; }) keys;
      operator = item: map (key: { inherit key; }) (concatMap (n: n.builds) (requirementNeeds item.key));
    });

  # The download entries of the locked files that installing the packages of
  # some categories needs.
  filesFor =
    selected:
    let
      chosen = concatMap lock.packagesOf selected;
      indexNeeds = map (p: needs p.key) (filter (p: p.kind == "index") chosen);
      # A local tree, a git checkout or a source archive from a URL is built
      # from its source, with the build requirements the lockfile has for it.
      directBuilds = filter (key: lock.builds ? ${key}) (
        map (p: p.key) (filter (p: p.kind != "index") chosen)
      );
      builds = buildClosure (directBuilds ++ concatMap (n: n.builds) indexNeeds);
      fileNames = lib.unique (
        concatMap (n: n.files) indexNeeds
        ++ concatMap (key: concatMap (n: n.files) (requirementNeeds key)) builds
      );
    in
    map (
      name:
      lock.files.${name}
        or (throw "pipenv-purifier: pipenv-purifier.lock.json has no URL of ${name}. Run `pipenv-purifier lock`.")
    ) fileNames;

  # The locked files that installing the packages of some categories needs,
  # as a wheelhouse.
  wheelhouseFor =
    selected:
    linkFarm "pipenv-purifier-wheelhouse" (
      map (file: {
        name = file.path;
        path = fetch file;
      }) (filesFor selected)
    );

  lockedSource =
    name:
    lock.sources.${name}
      or (throw "pipenv-purifier: pipenv-purifier.lock.json has no locked source of ${name}. Run `pipenv-purifier lock`.");
  isGit = name: lock.gitEntries ? ${(lockedSource name).artifact};

  # The locked file of a package from a URL.
  urlFile = name: fetch lock.files.${(lockedSource name).artifact};

  # A package from git, built into a wheel in a derivation of its own. A
  # backend that reads its version from git, through setuptools-scm or
  # hatch-vcs, finds no repository in the locked checkout, so it takes the
  # version the lock run read from the repository. The variable that gives
  # it applies to one package only in a build of that package alone.
  gitWheel =
    name: entry:
    let
      source = lockedSource name;
      checkout = fetch lock.gitEntries.${source.artifact};
    in
    stdenvNoCC.mkDerivation {
      pname = "${name}-wheel";
      version = if source.version != null then source.version else "0";
      src = if entry ? subdirectory then "${checkout}/${entry.subdirectory}" else checkout;
      env =
        pipEnv (wheelhouseFor lock.categories)
        // lib.optionalAttrs (source.version != null) { SETUPTOOLS_SCM_PRETEND_VERSION = source.version; };
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        ${pipSetup}
        ${buildFrontend.interpreter} -m build --wheel --outdir "$out" .
        runHook postBuild
      '';
      dontInstall = true;
      dontFixup = true;
    };

  # The packages from git of Pipfile.lock, by name, with their entries.
  gitEntriesByName = lib.listToAttrs (
    concatMap (
      category:
      map (p: {
        inherit (p) name;
        value = p.entry;
      }) (filter (p: p.kind == "git") (lock.packagesOf category))
    ) lock.categories
  );
  gitWheels = lib.mapAttrs gitWheel gitEntriesByName;

  # What the installs read for each package from git or a URL: the
  # directory with the wheel of a package from git, or the file of a package
  # from a URL.
  directInputs = lib.mapAttrs (
    name: _: if isGit name then "${gitWheels.${name}}" else "${urlFile name}"
  ) lock.sources;

  # Points each package from git at its wheel, in a copy of Pipfile.lock
  # that the rewriting below leaves @wheel:<name>@ in.
  substituteGitWheels = lib.concatMapStrings (name: ''
    wheel=(${gitWheels.${name}}/*.whl)
    sed -i "s|@wheel:${name}@|''${wheel[0]}|g" "$TMPDIR/pipfile/Pipfile.lock"
  '') (lib.attrNames gitWheels);

  # A local path of Pipfile.lock, in the copy of the project the build
  # makes, or, when it is outside the project, in the build's copy of what
  # `pathSources` gives for it (@outside:<path>@, which the build replaces).
  localPath =
    path:
    if lock.insideProject path then
      let
        normal = lock.normalizePath path;
      in
      if normal == "" then "@source@" else "@source@/${normal}"
    else
      "@outside:${path}@";

  # The local paths outside the project that Pipfile.lock names.
  outsidePaths = lib.unique (
    concatMap (
      category:
      map (p: p.entry.path) (
        filter (p: p.kind == "path" && !lock.insideProject p.entry.path) (lock.packagesOf category)
      )
    ) lock.categories
  );

  # Copies each local path outside the project into the build directory, as
  # stdenv copies the project, because a backend such as setuptools writes
  # into the source tree it builds, and points Pipfile.lock at the copy.
  copyOutsidePaths = lib.concatMapStrings (
    path:
    let
      source =
        pathSources.${path}
          or (throw "pipenv-purifier: Pipfile.lock names the local path ${path}, which is outside `src`. Pass it in `pathSources`, as `pathSources.\"${path}\" = <a Nix path>;`.");
      copy = "$TMPDIR/outside/${builtins.hashString "sha256" path}/${baseNameOf (toString source)}";
    in
    ''
      mkdir -p "$(dirname "${copy}")"
      cp -r ${source} "${copy}"
      chmod -R u+w "${copy}"
      sed -i "s|@outside:${path}@|${copy}|g" "$TMPDIR/pipfile/Pipfile.lock"
    ''
  ) outsidePaths;

  kindOf =
    entry:
    if entry ? git then
      "git"
    else if entry ? file then
      "file"
    else if entry ? path then
      "path"
    else
      "index";

  # Pipfile.lock for the build: every package from git is a path to its
  # wheel (@wheel:<name>@, which the build replaces), every package from a
  # URL a path to its locked file, and every local package a path into the
  # build's copy of the project (@source@, which the build replaces). Each of
  # them installs as a copy, because the result outlives the build
  # directory.
  rewrittenEntry =
    name: entry:
    let
      kind = kindOf entry;
      kept = removeAttrs entry [
        "git"
        "ref"
        "file"
        "subdirectory"
        "hashes"
        "path"
        "editable"
      ];
    in
    if builtins.elem name providedNames then
      (removeAttrs kept [ "version" ])
      // {
        path = "@provided:${name}@";
        editable = false;
      }
    else if kind == "git" then
      kept
      // {
        path = "@wheel:${name}@";
        editable = false;
      }
    else if kind == "file" then
      kept
      // {
        path = "${urlFile name}";
        editable = false;
      }
    else if kind == "path" then
      kept
      // {
        path = localPath entry.path;
        editable = false;
      }
    else
      entry;
  rewrittenLock = writeText "Pipfile.lock" (
    builtins.toJSON (
      lock.pipfileLock
      // lib.genAttrs lock.categories (
        category:
        lib.mapAttrs (name: entry: rewrittenEntry (lock.normalize name) entry) lock.pipfileLock.${category}
      )
    )
  );

  # pip reads the wheelhouse and nothing else.
  pipEnv = wheelhouse: {
    PIP_NO_INDEX = "1";
    PIP_FIND_LINKS = "${wheelhouse}";
    PIP_DISABLE_PIP_VERSION_CHECK = "1";
    PIPENV_YES = "1";
    PIPENV_NOSPIN = "1";
    # Pipenv notes that it installs into the virtual environment it runs
    # in, which is what the build asks of it.
    PIPENV_VERBOSITY = "-1";
  };
  # The setup hook of nixpkgs' Python puts the site-packages of Python
  # packages among the build inputs, such as Pipenv's own dependencies, on
  # PYTHONPATH. pip would take a package there as installed and leave the
  # locked one out of the environment, and an isolated build would import
  # it ahead of the locked build requirements. Pipenv's wrapper sets the
  # path that Pipenv itself needs.
  pipSetup = ''
    export HOME=$TMPDIR PIP_CACHE_DIR=$TMPDIR/pip-cache PIPENV_CACHE_DIR=$TMPDIR/pipenv-cache
    unset PYTHONPATH
  '';

  environmentOf =
    selected:
    stdenvNoCC.mkDerivation {
      pname = "pipenv-environment";
      version = "0";
      inherit src;
      nativeBuildInputs = [ runtimePipenv ];
      env = pipEnv (wheelhouseFor selected);
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        ${pipSetup}
        mkdir "$TMPDIR/pipfile"
        cp Pipfile "$TMPDIR/pipfile/Pipfile"
        sed "s|@source@|$PWD|g" ${rewrittenLock} > "$TMPDIR/pipfile/Pipfile.lock"
        ${substituteGitWheels}
        ${substituteProvided}
        ${copyOutsidePaths}
        ${interpreter.interpreter} -m venv "$out"
        export PIPENV_PURIFIER_EXPORT_WHEELS="$out/nix-support/wheels"
        ${lib.optionalString (
          projectInputs.dependencies != [ ]
        ) "export PIPENV_PURIFIER_BINDINGS=${projectInputs.bindings}/inputs.json"}
        VIRTUAL_ENV="$out" PIPENV_PIPFILE="$TMPDIR/pipfile/Pipfile" \
          pipenv sync --categories ${lib.escapeShellArg (lib.concatStringsSep " " selected)}
        runHook postBuild
      '';
      dontInstall = true;
    };
  environment = environmentOf categories;

  # The Pipfile's script `testScript`, which `pipenv run <testScript>` runs.
  # Pipenv runs a script as a command line, and so does the shell here.
  pipfile = builtins.fromTOML (builtins.readFile (src + "/Pipfile"));
  testCommand =
    let
      script =
        pipfile.scripts.${testScript}
          or (throw "pipenv-purifier: the Pipfile has no script `${testScript}` for `tests` to run. Add it under [scripts], or pass `testScript`.");
    in
    if builtins.isString script then
      script
    else
      throw "pipenv-purifier: the Pipfile's script `${testScript}` is a table; `tests` runs a script that is a command line.";

  # The tests run in a writable copy of the environment, as they run in a
  # project's .venv, because some tools write caches into the environment.
  # A virtual environment finds its packages from the directory of its
  # pyvenv.cfg.
  tests = stdenvNoCC.mkDerivation {
    pname = "pipenv-tests";
    version = "0";
    inherit src;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      ${pipSetup}
      cp -r ${
        environmentOf (if testCategories == null then lock.categories else testCategories)
      } "$TMPDIR/venv"
      chmod -R u+w "$TMPDIR/venv"
      export VIRTUAL_ENV=$TMPDIR/venv PATH=$TMPDIR/venv/bin:$PATH
      ${testCommand}
      runHook postBuild
    '';
    installPhase = "touch $out";
  };

  # A Python with `build`, the frontend that makes a local package's sdist
  # and wheel. It builds in an isolated environment that pip fills from the
  # wheelhouse.
  buildFrontend = interpreter.withPackages (ps: [ ps.build ]);

  packages = lib.mapAttrs (
    name: output:
    let
      normal = lock.normalizePath output.path;
      directory = if normal == "" then "." else normal;
      fail = what: ''
        echo "pipenv-purifier: building ${name} made $(ls "$out"), not the ${what} that pipenv-purifier.lock.json names. Run \`pipenv-purifier lock\`." >&2
        exit 1
      '';
      drv = stdenvNoCC.mkDerivation {
        pname = name;
        inherit (output) version;
        inherit src;
        outputs = [
          "out"
          "sdist"
          "wheel"
        ];
        env = pipEnv (wheelhouseFor lock.categories);
        dontConfigure = true;
        buildPhase = ''
          runHook preBuild
          ${pipSetup}
          ${buildFrontend.interpreter} -m build --outdir "$out" ${lib.escapeShellArg directory}
          [ -e "$out/"${lib.escapeShellArg output.sdist} ] || { ${fail output.sdist} }
          ${lib.optionalString output.pure ''
            [ -e "$out/"${lib.escapeShellArg output.wheel} ] || { ${fail output.wheel} }
          ''}
          wheels=("$out"/*.whl)
          cp "$out/"${lib.escapeShellArg output.sdist} "$sdist"
          cp "''${wheels[0]}" "$wheel"
          runHook postBuild
        '';
        dontInstall = true;
        dontFixup = true;
      };
    in
    drv.overrideAttrs {
      passthru.projections = projectionFor (environmentOf lock.categories) [ name ] name;
      passthru.artifacts = {
        inherit (drv) sdist wheel;
        ${output.sdist} = "${drv}/${output.sdist}";
      }
      // lib.optionalAttrs output.pure { ${output.wheel} = "${drv}/${output.wheel}"; };
    }
  ) lock.outputs;

  projectionFor =
    selectedEnvironment: roots: label:
    let
      scope =
        runCommand "${label}-publication-scope"
          {
            nativeBuildInputs = [ (interpreter.withPackages (ps: [ ps.packaging ])) ];
            outputs = [
              "out"
              "runtime"
            ];
            repositories = builtins.toJSON (map toString (lib.attrValues packages));
            roots = builtins.toJSON roots;
            passAsFile = [
              "repositories"
              "roots"
            ];
          }
          ''
            python ${./wheel_scope.py} --environment ${selectedEnvironment} \
              --repositories "$repositoriesPath" --roots "$rootsPath" \
              --destination "$out" --runtime "$runtime"
            mkdir -p "$runtime/nix-support"
            printf '%s\n' ${selectedEnvironment} > "$runtime/nix-support/inputs"
          '';
    in
    purifier.pythonProjections {
      repository = scope.out;
      runtimeRepository = scope.runtime;
      dependencies = projectInputs.dependencies;
      inherit runCommand;
      python3 = interpreter;
    };
  projections = projectionFor environment null "pipenv";

  programs = listToAttrs (
    concatMap (
      output:
      map (script: {
        name = script;
        value = runCommand script { meta.mainProgram = script; } ''
          mkdir -p $out/bin
          ln -s ${environment}/bin/${script} $out/bin/${script}
        '';
      }) output.scripts
    ) (lib.attrValues lock.outputs)
  );

  release =
    runCommand "pipenv-purifier-release"
      {
        passthru.projections =
          projectionFor (environmentOf lock.categories) (lib.attrNames packages)
            "pipenv-release";
      }
      ''
        mkdir $out
        ${lib.concatMapStrings (package: ''
          ln -s ${package}/* $out/
        '') (lib.attrValues packages)}
      '';

  # Every download of the lock, each with the systems it is needed on.
  fetches = read.entries;

  # What `pipenv-purifier prefetch` installs a development environment
  # from: the Python of the build, the wheelhouse of every category, and
  # what the installs read for the packages from git and URLs.
  prefetch = runCommand "pipenv-purifier-prefetch" { } ''
    mkdir $out
    ln -s ${interpreter.interpreter} $out/python
    ${lib.optionalString (
      projectInputs.dependencies != [ ]
    ) "ln -s ${projectInputs.bindings}/inputs.json $out/python-inputs.json"}
    ln -s ${wheelhouseFor lock.categories} $out/wheelhouse
    ln -s ${writeText "pipenv-purifier-direct.json" (builtins.toJSON directInputs)} $out/direct.json
  '';
in
{
  inherit
    packages
    projections
    tests
    release
    fetches
    environment
    programs
    prefetch
    ;
}
