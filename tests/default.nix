# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked files.
{
  pkgs,
  # The flake's default package overlay, which adds the scope
  # `pipenv-purifier` with buildPipenvProject.
  overlay,
  cli,
  # The shared purifier library, `lib.purifier` of its flake.
  purifier,
}:
let
  inherit (pkgs) lib runCommand;

  # Every fixture builds the way a consumer's package does: through
  # buildPipenvProject of a package set that the overlay applies to.
  build = (pkgs.extend overlay).pipenv-purifier.buildPipenvProject;

  # A hatchling project, installed from its own directory, that depends on
  # attrs, which installs from its wheel, and on docopt, which has only an
  # sdist and is built with the locked setuptools. six is a development
  # package. The Pipfile's script `test` runs its unit tests.
  simple = build { src = ./fixtures/simple; };
  simpleDevelop = build {
    src = ./fixtures/simple;
    categories = [
      "default"
      "develop"
    ];
  };
  # The custom category `tools` alone.
  simpleTools = build {
    src = ./fixtures/simple;
    categories = [ "tools" ];
  };

  # A project with a package of every kind Pipfile.lock records besides an
  # index: attrs from git (built with hatch-vcs, which reads its version
  # from git), six from a GitHub archive URL, and packages from a local
  # directory, a local sdist and a local wheel.
  sources = build { src = ./fixtures/sources; };

  # A project that depends on an editable path outside its directory,
  # which the build gets through pathSources.
  outside = build {
    src = ./fixtures/outside/app;
    pathSources."../shared" = ./fixtures/outside/shared;
  };

  # The simple fixture without pipenv-purifier.lock.json, as a flake that
  # packages a project without changing it holds its source, and the
  # lockfile kept apart from it.
  simpleWithoutLockfile = builtins.path {
    path = ./fixtures/simple;
    name = "simple-without-lockfile";
    filter = path: _: baseNameOf path != "pipenv-purifier.lock.json";
  };
  external = build {
    src = simpleWithoutLockfile;
    lockFile = ./fixtures/simple/pipenv-purifier.lock.json;
  };
  # The simple fixture without either lockfile, built with the copy of
  # Pipfile.lock that the packaging flake keeps.
  simpleWithoutLockfiles = builtins.path {
    path = ./fixtures/simple;
    name = "simple-without-lockfiles";
    filter =
      path: _:
      !builtins.elem (baseNameOf path) [
        "pipenv-purifier.lock.json"
        "Pipfile.lock"
      ];
  };
  externalToolLock = build {
    src = simpleWithoutLockfiles;
    lockFile = ./fixtures/simple/pipenv-purifier.lock.json;
    pipfileLock = ./fixtures/simple/Pipfile.lock;
  };

  # A real-world project: Pipenv's own repository, which develops Pipenv
  # with a Pipfile. Its Pipfile.lock pins 91 packages, among them Sphinx,
  # pre-commit, gunicorn, and pyyaml 6.0.1, which has no wheel for Python
  # 3.14 and builds from its sdist with Cython. The lockfile beside this
  # file is what `pipenv-purifier lock` wrote for that commit.
  # Lock validation reads Pipfile at evaluation time on either system.
  realWorldPipenvSource = builtins.fetchTarball {
    url = "https://github.com/pypa/pipenv/archive/fef029307389de23d0704407e4d0ebf1d1b17758.tar.gz";
    sha256 = "sha256-3su6oPoEuY/sL3tQjMu44KRYkDhruJAMxTpzzdtYHJQ=";
  };
  realWorldPipenv = build {
    src = realWorldPipenvSource;
    lockFile = ./real-world/pipenv/pipenv-purifier.lock.json;
    categories = [
      "default"
      "develop"
    ];
  };

  # pypiserver imports cgi, which Python 3.13 removed; legacy-cgi provides
  # it.
  pypiserver = pkgs.python3.withPackages (ps: [
    ps.pypiserver
    ps.legacy-cgi
  ]);

  # Every locked file of the simple fixture, for every system, in one
  # directory, which a local package index serves.
  simpleLock = builtins.fromJSON (builtins.readFile ./fixtures/simple/pipenv-purifier.lock.json);
  simplePipfileLock = builtins.fromJSON (builtins.readFile ./fixtures/simple/Pipfile.lock);
  simpleFiles = pkgs.linkFarm "pipenv-purifier-test-simple-files" (
    map (entry: {
      name = entry.path;
      path = purifier.fetchEntry { inherit pkgs; } entry;
    }) (lib.attrValues (import ../nix/lib/lock.nix { src = ./fixtures/simple; }).views.files)
  );
  # An older six, which the local index of conformance-update serves.
  six16 = pkgs.fetchurl {
    url = "https://files.pythonhosted.org/packages/d9/5a/e7c31adbe875f2abbb91bd84cf2dc52d792b5a01506781dbcf25c91daf11/six-1.16.0-py2.py3-none-any.whl";
    sha256 = "8abb2f1d86890a2dfb989f9a77cfcfd3e47c2a354b01111771326f8aa26e0254";
  };
  attrsHashes = map (lib.removePrefix "sha256:") simplePipfileLock.default.attrs.hashes;

  # A copy of the simple fixture's pipenv-purifier.lock.json, changed by
  # `change`, whose contentHash is that of its new content, as a lock run
  # would write it.
  rehashed =
    name: change:
    let
      changed = removeAttrs (change simpleLock) [ "contentHash" ];
    in
    builtins.toFile "${name}.json" (
      builtins.toJSON (
        changed // { contentHash = builtins.hashString "sha256" (builtins.toJSON changed); }
      )
    );

  # Starts a package index on 127.0.0.1:<port> that serves a directory and
  # takes uploads into it without authentication, and waits until it
  # answers. Each check that starts one has a port of its own: darwin
  # builds share the host's network, so two checks building at once on one
  # port would share one index.
  startIndex = port: directory: ''
    ${pypiserver.interpreter} -m pypiserver run --port ${toString port} --host 127.0.0.1 \
      --authenticate . --passwords . --disable-fallback ${directory} &
    # Darwin builds have no PID namespace, so a server left running would
    # keep the build's log open after the builder exits.
    server=$!
    trap 'kill $server' EXIT
    for _ in $(seq 100); do
      ${pkgs.python3.interpreter} -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:${toString port}/simple/")' 2>/dev/null && break
      sleep 0.1
    done
  '';

  # Runs a program and compares what it prints.
  runs =
    name: program: expected:
    runCommand "pipenv-purifier-test-${name}" { } ''
      output=$(${program})
      echo "$output"
      if [ "$output" != ${lib.escapeShellArg expected} ]; then
        echo "expected: "${lib.escapeShellArg expected} >&2
        exit 1
      fi
      touch $out
    '';

  # Runs `pipenv-purifier prefetch` on a copy of a fixture, with the inputs
  # Nix built for it, then runs a script of the .venv it installed. `edit`
  # changes the project's source afterwards, and the script runs again: a
  # local package installed as editable prints `edited`. `loop` runs after
  # that, with Pipenv on the PATH; the sandbox has no network.
  prefetches =
    name:
    {
      fixture,
      project,
      script,
      expected,
      edit,
      edited,
      loop ? "",
    }:
    runCommand "pipenv-purifier-test-${name}" { nativeBuildInputs = [ cli ]; } ''
      cp -r ${fixture} project
      chmod -R u+w project
      cd project
      # Python checks its cached bytecode by the modification time in
      # seconds and the size of the source, so the edit right after the
      # first run would go unseen through a cache.
      export HOME=$TMPDIR PYTHONDONTWRITEBYTECODE=1
      pipenv-purifier prefetch --inputs ${project.prefetch}
      check() {
        output=$(.venv/bin/${script})
        echo "$output"
        if [ "$output" != "$1" ]; then
          echo "expected: $1" >&2
          exit 1
        fi
      }
      check ${lib.escapeShellArg expected}
      ${edit}
      check ${lib.escapeShellArg edited}
      PATH=${pkgs.pipenv}/bin:$PATH
      ${loop}
      touch $out
    '';

  # Copies the simple fixture and lets `damage` change it. Then
  # `pipenv-purifier prefetch` and the Nix library's reading of the
  # lockfiles both have to refuse the project, with errors that match
  # `pattern`. Nix evaluates the reading in the build, with a store that
  # writes nothing, and the check reads the error that a build would show:
  # the problems of the lock in memory, which checkLock throws, or the
  # error of reading a file that is not JSON.
  # With `command = false`, only the Nix library is asked: the command
  # leaves that check to the Nix build it runs.
  refuses =
    name:
    {
      damage,
      pattern,
      command ? true,
    }:
    runCommand "pipenv-purifier-test-${name}"
      {
        nativeBuildInputs = [
          cli
          pkgs.nix
        ];
      }
      ''
        cp -r ${./fixtures/simple} project
        chmod -R u+w project
        cd project
        export HOME=$TMPDIR NIX_STATE_DIR=$TMPDIR/nix-state NIX_CONF_DIR=$TMPDIR
        ${damage}
        ${lib.optionalString command ''
          if pipenv-purifier prefetch --inputs ${simple.prefetch} 2> "$TMPDIR/command-error"; then
            echo "prefetch accepted the damaged project" >&2
            exit 1
          fi
          cat "$TMPDIR/command-error"
          grep -q ${lib.escapeShellArg pattern} "$TMPDIR/command-error"
          test ! -e .venv/bin/simple
        ''}
        if nix-instantiate --eval --strict --store dummy:// \
          --expr "let lock = import ${../nix/lib}/lock.nix { src = $PWD; }; in if lock.problems == [ ] then builtins.deepSeq lock.entries true else throw (builtins.concatStringsSep \"\n\" lock.problems)" \
          2> "$TMPDIR/nix-error"; then
          echo "the Nix library accepted the damaged project" >&2
          exit 1
        fi
        cat "$TMPDIR/nix-error"
        grep -q ${lib.escapeShellArg pattern} "$TMPDIR/nix-error"
        touch $out
      '';

  # The simple fixture's sdist and wheel, built a second time in a
  # derivation of another name.
  simpleAgain = simple.packages.simple.overrideAttrs { pname = "simple-again"; };
in
{
  composition-producer = simple.packages.simple;
  python-projection =
    runCommand "pipenv-native-projection-downstream"
      {
        nativeBuildInputs = [
          pkgs.uv
          pkgs.python3
        ];
      }
      ''
        export HOME=$TMPDIR UV_CACHE_DIR=$TMPDIR/uv-cache UV_PYTHON_DOWNLOADS=never
        uv venv --python ${pkgs.python3.interpreter} downstream
        uv pip install --python downstream/bin/python --no-index \
          --find-links ${simple.packages.simple.projections.python} simple
        downstream/bin/simple > result
        grep -q 'attrs=25.3.0' result
        downstream/bin/python - <<'PYTHON'
        from importlib.metadata import version
        assert '+nix.' in version('simple')
        PYTHON
        touch $out
      '';
  simple =
    runs "simple" "${simple.environment}/bin/simple"
      "simple attrs=25.3.0 docopt=0.6.2 markupsafe=3.0.3";

  # The program of the script `simple`, which `nix run` runs.
  simple-program =
    runs "simple-program" (lib.getExe simple.programs.simple)
      "simple attrs=25.3.0 docopt=0.6.2 markupsafe=3.0.3";

  # The fixture's unit tests, which the Pipfile's script `test` runs, with
  # the packages of every category.
  simple-tests = simple.tests;

  # `default` alone leaves out the development package six and the package
  # of the custom category `tools`, and each category adds its packages.
  simple-categories = runCommand "pipenv-purifier-test-categories" { } ''
    ${simple.environment}/bin/python -c 'import six' 2>/dev/null && { echo "six is in the default environment" >&2; exit 1; }
    ${simple.environment}/bin/python -c 'import iniconfig' 2>/dev/null && { echo "iniconfig is in the default environment" >&2; exit 1; }
    ${simpleDevelop.environment}/bin/python -c 'import six; print(six.__version__)'
    ${simpleTools.environment}/bin/python -c 'import iniconfig; print(iniconfig.__name__)'
    touch $out
  '';

  # A local package's sdist and wheel, named without building by the
  # lockfile, and the release, which holds both.
  simple-package = runCommand "pipenv-purifier-test-simple-package" { } ''
    test -f ${simple.packages.simple.artifacts."simple-0.1.0.tar.gz"}
    test -f ${simple.packages.simple.artifacts."simple-0.1.0-py3-none-any.whl"}
    test -f ${simple.packages.simple.artifacts.sdist}
    test -f ${simple.packages.simple.artifacts.wheel}
    test -f ${simple.release}/simple-0.1.0.tar.gz
    test -f ${simple.release}/simple-0.1.0-py3-none-any.whl
    touch $out
  '';

  sources =
    runs "sources" "${sources.environment}/bin/sources"
      "attrs=25.3.0 six=1.17.0 localdir 0.3.0 localsdist 0.4.0 localwheel 0.5.0";

  # `fetches` lists the git checkout and the archive from a URL with the
  # files of the index.
  sources-fetches =
    let
      kinds = map (entry: if entry ? git then "git" else "file") sources.fetches;
      paths = map (entry: entry.path) sources.fetches;
    in
    assert lib.elem "git" kinds;
    assert lib.length paths == lib.length (lib.unique paths);
    assert lib.any (path: lib.hasPrefix "file/" path) paths;
    runCommand "pipenv-purifier-test-sources-fetches" { } "touch $out";

  outside = runs "outside" "${outside.environment}/bin/outside-app" "outside-app with shared 0.2.0";

  prefetch-sources = prefetches "prefetch-sources" {
    fixture = ./fixtures/sources;
    project = sources;
    script = "sources";
    expected = "attrs=25.3.0 six=1.17.0 localdir 0.3.0 localsdist 0.4.0 localwheel 0.5.0";
    edit = "sed -i 's/attrs=/attrs: /' src/sources/__init__.py";
    edited = "attrs: 25.3.0 six=1.17.0 localdir 0.3.0 localsdist 0.4.0 localwheel 0.5.0";
  };

  # After `prefetch`, the development loop works with no network: `pipenv run`
  # of the project's script and of its tests, in the .venv that `prefetch`
  # installed, after an edit to the editable local package.
  conformance-offline = prefetches "conformance-offline" {
    fixture = ./fixtures/simple;
    project = simple;
    script = "simple";
    expected = "simple attrs=25.3.0 docopt=0.6.2 markupsafe=3.0.3";
    edit = "sed -i 's/simple {versions}/edited {versions}/' src/simple/__init__.py";
    edited = "edited attrs=25.3.0 docopt=0.6.2 markupsafe=3.0.3";
    loop = ''
      sed -i 's/edited {versions}/simple {versions}/' src/simple/__init__.py
      test "$(pipenv --venv)" = "$PWD/.venv"
      pipenv run simple
      pipenv run test
    '';
  };

  # A package added to the Pipfile by hand, without `pipenv lock`:
  # `prefetch` refuses before installing anything and names the commands to
  # run.
  prefetch-stale-pipfile =
    runCommand "pipenv-purifier-test-prefetch-stale-pipfile" { nativeBuildInputs = [ cli ]; }
      ''
        cp -r ${./fixtures/simple} project
        chmod -R u+w project
        cd project
        export HOME=$TMPDIR
        sed -i 's/^attrs = "==25.3.0"$/attrs = "==25.3.0"\nidna = "*"/' Pipfile
        if pipenv-purifier prefetch --inputs ${simple.prefetch} 2> "$TMPDIR/error"; then
          echo "prefetch accepted a Pipfile that Pipfile.lock does not match" >&2
          exit 1
        fi
        cat "$TMPDIR/error"
        grep -q 'run `pipenv-purifier lock`, which writes Pipfile.lock with `pipenv lock` first' "$TMPDIR/error"
        test ! -e .venv/bin/simple
        touch $out
      '';

  # Pipfile.lock changed, as after `pipenv install`, without
  # `pipenv-purifier lock`.
  conformance-stale = refuses "conformance-stale" {
    damage = ''sed -i 's/"==25.3.0"/"==25.3.0" /' Pipfile.lock'';
    pattern = "match.*un `pipenv-purifier lock`";
  };

  # The URL of the attrs wheel recorded under another hash: the lockfile's
  # contentHash no longer matches, and, with the contentHash written again,
  # neither lockfile lists the hash.
  conformance-tampered =
    let
      wheelHash = lib.head attrsHashes;
      tampered = rehashed "tampered" (
        l:
        l
        // {
          urls = removeAttrs l.urls [ wheelHash ] // {
            ${lib.fixedWidthString 64 "0" ""} = l.urls.${wheelHash};
          };
        }
      );
    in
    pkgs.linkFarm "pipenv-purifier-test-conformance-tampered" {
      edited = refuses "conformance-tampered-edited" {
        damage = ''sed -i '0,/"https:/s|"https:|"http:|' pipenv-purifier.lock.json'';
        pattern = "edited after `pipenv-purifier lock`.*un `pipenv-purifier lock`";
      };
      rehashed = refuses "conformance-tampered-rehashed" {
        damage = "cp ${tampered} pipenv-purifier.lock.json";
        pattern = "neither Pipfile.lock nor its build packages list.*Run `pipenv-purifier lock`";
        command = false;
      };
    };

  # A lockfile without what the build needs: no lockfile at all, no URL of
  # any file of a package that Pipfile.lock pins, and no hashes of the
  # packages that only the build requirements need.
  conformance-missing = pkgs.linkFarm "pipenv-purifier-test-conformance-missing" {
    lockfile = refuses "conformance-missing-lockfile" {
      damage = "rm pipenv-purifier.lock.json";
      pattern = "pipenv-purifier.lock.json.*pipenv-purifier lock";
    };
    package = refuses "conformance-missing-package" {
      damage = "cp ${
        rehashed "missing-package" (l: l // { urls = removeAttrs l.urls attrsHashes; })
      } pipenv-purifier.lock.json";
      pattern = "no files of attrs==25.3.0, which Pipfile.lock pins.*Run `pipenv-purifier lock`";
      command = false;
    };
    build-package = refuses "conformance-missing-build-package" {
      damage = "cp ${
        rehashed "missing-build-package" (l: l // { buildPackages = { }; })
      } pipenv-purifier.lock.json";
      pattern = "which a set of build requirements needs.*Run `pipenv-purifier lock`";
      command = false;
    };
  };

  # A lockfile that is not valid: not JSON, JSON that is no lockfile of
  # this format, and a lockfile of another format version.
  conformance-malformed = pkgs.linkFarm "pipenv-purifier-test-conformance-malformed" {
    not-json = refuses "conformance-malformed-not-json" {
      damage = "head -c 100 ${./fixtures/simple/pipenv-purifier.lock.json} > pipenv-purifier.lock.json";
      pattern = "pipenv-purifier lock";
    };
    not-a-lockfile = refuses "conformance-malformed-not-a-lockfile" {
      damage = ''echo '{"hello": "world"}' > pipenv-purifier.lock.json'';
      pattern = "not a .*lockfile.*un `pipenv-purifier lock`";
    };
    other-version = refuses "conformance-malformed-other-version" {
      damage = "cp ${rehashed "other-version" (l: l // { version = 99; })} pipenv-purifier.lock.json";
      pattern = "un `pipenv-purifier lock`";
    };
  };

  # The lock run, against a local index that serves the files of the simple
  # fixture's lock: `pipenv lock`, then `pipenv-purifier lock`, which has to
  # find every file, resolve the same build requirements and record the same
  # outputs as the committed lockfile. The index serves PEP 503 pages, so
  # this also covers the lock tool's reading of HTML index pages.
  conformance-relock =
    runCommand "pipenv-purifier-test-conformance-relock"
      {
        nativeBuildInputs = [
          cli
          pkgs.pipenv
        ];
      }
      ''
        export HOME=$TMPDIR PIPENV_VENV_IN_PROJECT=1 PIPENV_YES=1 PIPENV_NOSPIN=1
        export PIPENV_PYTHON=${pkgs.python3.interpreter}
        export PIPENV_CACHE_DIR=$TMPDIR/pipenv-cache PIP_CACHE_DIR=$TMPDIR/pip-cache
        mkdir packages
        cp ${simpleFiles}/* packages/
        ${startIndex 8080 "packages"}
        cp -r ${./fixtures/simple} project
        chmod -R u+w project
        cd project
        sed -i 's|https://pypi.org/simple|http://127.0.0.1:8080/simple|' Pipfile
        # The Pipfile no longer matches Pipfile.lock, so `pipenv-purifier
        # lock` writes Pipfile.lock with `pipenv lock` first.
        pipenv-purifier lock
        pipenv verify
        cp Pipfile.lock "$TMPDIR/Pipfile.lock"
        rm -rf .venv
        pipenv-purifier lock
        # A Pipfile.lock that matches the Pipfile stays as it is.
        cmp "$TMPDIR/Pipfile.lock" Pipfile.lock
        cp pipenv-purifier.lock.json "$TMPDIR/first.json"
        # A second lock run makes the same bytes.
        pipenv-purifier lock
        cmp "$TMPDIR/first.json" pipenv-purifier.lock.json
        # The lockfile is the committed one byte for byte, once each URL is
        # the committed URL of the same file: the local index serves the
        # files under URLs of its own, so the hashes of the lockfile's
        # content and of Pipfile.lock differ too.
        ${pkgs.python3.interpreter} - ${./fixtures/simple/pipenv-purifier.lock.json} pipenv-purifier.lock.json <<'EOF'
        import json, sys
        committed_path, made_path = sys.argv[1:]
        committed = json.load(open(committed_path))
        made = json.load(open(made_path))
        if sorted(made["urls"]) != sorted(committed["urls"]):
            sys.exit(f"the lock run recorded URLs of other files:\n{sorted(made['urls'])}\n{sorted(committed['urls'])}")
        made["urls"] = committed["urls"]
        made["inputsHash"] = committed["inputsHash"]
        made["contentHash"] = committed["contentHash"]
        if json.dumps(made, indent=2) + "\n" != open(committed_path).read():
            for key in committed:
                if committed[key] != made.get(key):
                    print(f"{key} differs:\n{committed[key]}\n{made.get(key)}", file=sys.stderr)
            sys.exit(1)
        EOF
        # --lockfile writes the lockfile outside the project.
        pipenv-purifier lock --lockfile "$TMPDIR/outside.json"
        cmp "$TMPDIR/first.json" "$TMPDIR/outside.json"
        # With --tool-lockfile, the first lock run copies Pipfile.lock from
        # the project to the outside path and leaves the copy in the project
        # as it is. The lockfile is the same, because Pipfile.lock is.
        pipenv-purifier lock --lockfile "$TMPDIR/external/lock.json" --tool-lockfile "$TMPDIR/external/Pipfile.lock"
        cmp "$TMPDIR/Pipfile.lock" "$TMPDIR/external/Pipfile.lock"
        cmp "$TMPDIR/Pipfile.lock" Pipfile.lock
        cmp "$TMPDIR/first.json" "$TMPDIR/external/lock.json"
        touch $out
      '';

  # `update six` on a copy of the simple fixture whose Pipfile allows any
  # six, locked while the local index served only six 1.16.0. With six
  # 1.17.0 on the index too, `update` re-resolves six to 1.17.0 and relocks,
  # and both lockfiles then pass the check for a stale lockfile, in the
  # command and in the Nix library.
  conformance-update =
    runCommand "pipenv-purifier-test-conformance-update"
      {
        nativeBuildInputs = [
          cli
          pkgs.pipenv
          pkgs.nix
        ];
      }
      ''
        export HOME=$TMPDIR PIPENV_VENV_IN_PROJECT=1 PIPENV_YES=1 PIPENV_NOSPIN=1
        export PIPENV_PYTHON=${pkgs.python3.interpreter}
        export PIPENV_CACHE_DIR=$TMPDIR/pipenv-cache PIP_CACHE_DIR=$TMPDIR/pip-cache
        export NIX_STATE_DIR=$TMPDIR/nix-state NIX_CONF_DIR=$TMPDIR
        mkdir packages
        cp ${simpleFiles}/* packages/
        mv packages/six-1.17.0* "$TMPDIR/"
        cp ${six16} packages/six-1.16.0-py2.py3-none-any.whl
        ${startIndex 8081 "packages"}
        cp -r ${./fixtures/simple} project
        chmod -R u+w project
        cd project
        sed -i 's|https://pypi.org/simple|http://127.0.0.1:8081/simple|; s|^six = "==1.17.0"$|six = "*"|' Pipfile
        pipenv lock
        rm -rf .venv
        pipenv-purifier lock
        grep -q '"version": "==1.16.0"' Pipfile.lock
        mv "$TMPDIR"/six-1.17.0* ../packages/
        pipenv-purifier update six
        grep -q '"version": "==1.17.0"' Pipfile.lock
        pipenv verify
        pipenv-purifier prefetch --inputs ${simple.prefetch} --categories tools
        nix-instantiate --eval --strict --store dummy:// \
          --expr "(import ${../nix/lib}/lock.nix { src = $PWD; }).problems" > "$TMPDIR/problems"
        cat "$TMPDIR/problems"
        test "$(cat "$TMPDIR/problems")" = "[ ]"
        touch $out
      '';

  # A build of the simple environment with a PYTHONPATH, as the setup hook
  # of nixpkgs' Python sets one, that holds a fake attrs at the locked
  # version. The environment still installs every locked package inside
  # itself, at its locked version, because the build ignores PYTHONPATH.
  environment-pythonpath =
    let
      fakeAttrs = runCommand "fake-attrs" { } ''
        mkdir -p $out/attrs $out/attrs-25.3.0.dist-info
        echo 'raise ImportError("the fake attrs on PYTHONPATH")' > $out/attrs/__init__.py
        printf 'Metadata-Version: 2.1\nName: attrs\nVersion: 25.3.0\n' > $out/attrs-25.3.0.dist-info/METADATA
        touch $out/attrs-25.3.0.dist-info/RECORD
      '';
      environment = simpleDevelop.environment.overrideAttrs (old: {
        preBuild = (old.preBuild or "") + ''
          export PYTHONPATH=${fakeAttrs}''${PYTHONPATH:+:$PYTHONPATH}
        '';
      });
    in
    runCommand "pipenv-purifier-test-environment-pythonpath" { } ''
      ${environment}/bin/python -I ${./locked-in-venv.py} ${./fixtures/simple/Pipfile.lock} default develop
      ${environment}/bin/simple
      touch $out
    '';

  # Every locked package of Pipenv's repository is inside its environment,
  # at its locked version.
  real-world-pipenv-locked = runCommand "pipenv-purifier-test-real-world-pipenv-locked" { } ''
    ${realWorldPipenv.environment}/bin/python -I ${./locked-in-venv.py} ${realWorldPipenvSource}/Pipfile.lock default develop
    touch $out
  '';

  # The sdist and wheel of a local package, built twice, are the same bytes.
  conformance-rebuild = runCommand "pipenv-purifier-test-conformance-rebuild" { } ''
    for file in simple-0.1.0.tar.gz simple-0.1.0-py3-none-any.whl; do
      cmp ${simple.packages.simple}/$file ${simpleAgain}/$file
    done
    touch $out
  '';

  # The simple fixture builds from lockfiles kept outside its source, and
  # `prefetch --lockfile` reads a lockfile outside the project.
  conformance-external =
    runCommand "pipenv-purifier-test-conformance-external" { nativeBuildInputs = [ cli ]; }
      ''
        test "$(${external.environment}/bin/simple)" = "simple attrs=25.3.0 docopt=0.6.2 markupsafe=3.0.3"
        test "$(${externalToolLock.environment}/bin/simple)" = "simple attrs=25.3.0 docopt=0.6.2 markupsafe=3.0.3"
        export HOME=$TMPDIR
        cp -r ${./fixtures/simple} project
        chmod -R u+w project
        mv project/pipenv-purifier.lock.json lock.json
        (
          cd project
          pipenv-purifier prefetch --lockfile ../lock.json --inputs ${external.prefetch}
          test "$(.venv/bin/simple)" = "simple attrs=25.3.0 docopt=0.6.2 markupsafe=3.0.3"
        )
        # The project holds a Pipfile.lock that is no lockfile at all, and
        # the commands read the copy kept outside, through the environment
        # variables a dev shell of the packaging flake sets.
        rm -rf project
        cp -r ${./fixtures/simple} project
        chmod -R u+w project
        mv project/pipenv-purifier.lock.json lock.json
        mv project/Pipfile.lock Pipfile.lock
        echo '{}' > project/Pipfile.lock
        cd project
        PIPENV_PURIFIER_LOCKFILE=../lock.json PIPENV_PURIFIER_TOOL_LOCKFILE=../Pipfile.lock \
          pipenv-purifier prefetch --inputs ${externalToolLock.prefetch}
        test "$(.venv/bin/simple)" = "simple attrs=25.3.0 docopt=0.6.2 markupsafe=3.0.3"
        test "$(cat Pipfile.lock)" = '{}'
        touch $out
      '';

  # `publish --release` uploads the sdist and wheel Nix built to an index.
  publish = runCommand "pipenv-purifier-test-publish" { nativeBuildInputs = [ cli ]; } ''
    export HOME=$TMPDIR UV_CACHE_DIR=$TMPDIR/uv-cache
    mkdir packages
    ${startIndex 8082 "packages"}
    pipenv-purifier publish --release ${simple.release} -- \
      --publish-url http://127.0.0.1:8082/ --username user --password password
    test -f packages/simple-0.1.0.tar.gz
    test -f packages/simple-0.1.0-py3-none-any.whl
    touch $out
  '';

  # Pipenv's unit tests, run from its source with the environment the
  # purifier built from its lockfiles.
  real-world-pipenv = runCommand "pipenv-purifier-test-real-world-pipenv" { } ''
    cp -r ${realWorldPipenvSource} pipenv
    chmod -R u+w pipenv
    cd pipenv
    # The tests run as `pipenv run pytest` runs them, inside the
    # environment. Pipenv writes a cache of package names into the
    # environment, so they run in a writable copy of it; a virtual
    # environment finds its packages from the directory of its pyvenv.cfg.
    cp -r ${realWorldPipenv.environment} "$TMPDIR/venv"
    chmod -R u+w "$TMPDIR/venv"
    export HOME=$TMPDIR VIRTUAL_ENV=$TMPDIR/venv
    # test_release_tasks.py imports bs4, which Pipenv's Pipfile does not
    # list, so no environment of that Pipfile has it. Four tests download
    # from PyPI, which the sandbox cannot reach: the three tests of
    # test_pylock.py that read a lockfile, and the live resolve.
    "$VIRTUAL_ENV/bin/python" -m pytest tests/unit -q -p no:cacheprovider \
      --ignore=tests/unit/test_release_tasks.py \
      --deselect tests/unit/test_pylock.py::test_from_lockfile \
      --deselect tests/unit/test_pylock.py::test_from_lockfile_with_custom_dev_groups \
      --deselect tests/unit/test_pylock.py::test_from_lockfile_adds_package_index \
      --deselect tests/unit/test_resolver_protocol_smoke.py::test_resolver_subprocess_live_resolve_against_pypi
    touch $out
  '';

  nix-library = import ./nix-library.nix { inherit pkgs purifier; };

  # The lock tool's unit tests, on the Python and packages the CLI runs on.
  unit =
    runCommand "pipenv-purifier-test-unit"
      {
        nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.packaging ])) ];
      }
      ''
        cp ${../src/pipenv_purifier.py} pipenv_purifier.py
        cp ${./test_pipenv_purifier.py} test_pipenv_purifier.py
        python -m unittest -v test_pipenv_purifier
        touch $out
      '';

  cli = runCommand "pipenv-purifier-test-cli" { } ''
    ${lib.getExe cli} --help
    ${lib.getExe cli} lock --help
    ${lib.getExe cli} update --help
    ${lib.getExe cli} prefetch --help
    ${lib.getExe cli} publish --help
    touch $out
  '';
}
