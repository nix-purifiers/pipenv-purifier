# SPDX-License-Identifier: MIT
#
# `readLock` of the purifier contract: reads a Pipenv project's two
# lockfiles, Pipfile.lock, which Pipenv writes, and
# pipenv-purifier.lock.json, which `pipenv-purifier lock` writes beside it,
# into the lock in memory, `{ purifier, entries, outputs, problems }`, with
# what the builder reads of them under `views`. pipenv-purifier.lock.json records only what Pipfile.lock cannot
# (src/pipenv_purifier.py, lock), and this file derives the rest: the name
# and hash of each file of an index, the URL and commit of each package from
# git or a URL, and the version and path of each local package.
{
  # The project root, which holds the Pipfile.
  src,
  lockFile ? src + "/pipenv-purifier.lock.json",
  # Pipfile.lock, which Pipenv writes in the project. An external build may
  # keep its own copy, which is read in place of the one in `src`.
  pipfileLock ? src + "/Pipfile.lock",
}:
let
  inherit (builtins)
    attrNames
    attrValues
    concatLists
    concatStringsSep
    elemAt
    filter
    fromJSON
    genList
    hashFile
    hashString
    head
    listToAttrs
    map
    readFile
    replaceStrings
    sort
    split
    substring
    stringLength
    ;

  supportedVersion = import ./lock-version.nix;

  purifier = builtins.addErrorContext "while reading ${toString lockFile}, which `pipenv-purifier lock` writes; run it again if the file is damaged" (
    fromJSON (readFile lockFile)
  );
  pipfileLockData = builtins.addErrorContext "while reading ${toString pipfileLock}, which `pipenv lock` writes; run it again if the file is damaged" (
    fromJSON (readFile pipfileLock)
  );

  # The fields a lockfile of this format has.
  purifierFields = [
    "version"
    "contentHash"
    "inputsHash"
    "urls"
    "buildPackages"
    "buildRequirements"
    "builds"
    "sources"
    "outputs"
  ];
  missingFields = filter (field: !(builtins.isAttrs purifier && purifier ? ${field})) purifierFields;

  concatMap = f: list: concatLists (map f list);
  unique =
    list:
    attrNames (
      listToAttrs (
        map (x: {
          name = x;
          value = null;
        }) list
      )
    );
  hasPrefix = prefix: text: substring 0 (stringLength prefix) text == prefix;
  hasSuffix =
    suffix: text:
    let
      n = stringLength text;
      m = stringLength suffix;
    in
    n >= m && substring (n - m) m text == suffix;

  letters = text: genList (i: substring i 1 text) 26;
  lower = replaceStrings (letters "ABCDEFGHIJKLMNOPQRSTUVWXYZ") (
    letters "abcdefghijklmnopqrstuvwxyz"
  );

  # A project name as PEP 503 normalizes it (src/pipenv_purifier.py,
  # normalize): lower case, with every run of "-", "_" and "." one "-".
  normalize = name: lower (concatStringsSep "-" (filter builtins.isString (split "[-_.]+" name)));

  # The last segment of a URL, without its query and fragment, with its
  # percent escapes decoded (src/pipenv_purifier.py, file_name). An escape
  # of a printable ASCII character is decoded; file names of distributions
  # have no others.
  printable = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
  hexDigits = genList (i: substring i 1 "0123456789abcdef") 16;
  hexDigit = c: head (filter (i: elemAt hexDigits i == lower c) (genList (i: i) 16));
  decodeEscape =
    hex:
    let
      code = hexDigit (substring 0 1 hex) * 16 + hexDigit (substring 1 1 hex);
    in
    if code < 32 || code > 126 then
      throw "pipenv-purifier: a URL in ${toString lockFile} escapes the byte %${hex}, which no file name of a distribution has"
    else
      substring (code - 32) 1 printable;
  fileName =
    url:
    concatStringsSep "" (
      map (part: if builtins.isList part then decodeEscape (head part) else part) (
        split "%([0-9A-Fa-f]{2})" (baseNameOf (head (split "[?#]" url)))
      )
    );

  isWheel = hasSuffix ".whl";
  isSdist =
    name:
    builtins.any (suffix: hasSuffix suffix name) [
      ".tar.gz"
      ".zip"
      ".tar.bz2"
      ".tar.xz"
      ".tgz"
    ];
  # A wheel whose ABI tag is `none` and platform tag is `any`
  # (src/pipenv_purifier.py, is_pure_wheel).
  isPureWheel = hasSuffix "-none-any.whl";

  # The package categories of Pipfile.lock: `default`, `develop` and any
  # custom category of the Pipfile.
  categories = filter (k: k != "_meta") (attrNames pipfileLockData);

  insideProject = path: !(path == ".." || hasPrefix "/" path || hasPrefix "../" path);

  # A relative path without "." segments and trailing slashes, the way the
  # lock tool records paths with os.path.normpath; "" for the project root.
  normalizePath =
    path:
    concatStringsSep "/" (filter (s: builtins.isString s && s != "" && s != ".") (split "/" path));

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

  version = entry: replaceStrings [ "==" ] [ "" ] (entry.version or "");

  # The packages of one category, each with its normalized name, its key
  # ("<name>==<version>" for a package of an index, the name otherwise), its
  # kind and its entry of Pipfile.lock.
  packagesOf =
    category:
    map
      (
        name:
        let
          entry = pipfileLockData.${category}.${name};
          kind = kindOf entry;
        in
        {
          name = normalize name;
          inherit kind entry;
          key = if kind == "index" then "${normalize name}==${version entry}" else normalize name;
        }
      )
      (
        filter (name: !(builtins.elem (normalize name) (purifier.projectInputNames or [ ]))) (
          attrNames pipfileLockData.${category}
        )
      );
  allPackages = concatMap packagesOf categories;

  hexOf = hash: replaceStrings [ "sha256:" ] [ "" ] hash;
  sriOf =
    hex:
    builtins.convertHash {
      hash = hex;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };

  # The sha256 hashes of the files of every package of an index: the ones
  # Pipfile.lock lists, and for a package that only build requirements need,
  # the ones of `buildPackages`.
  indexPackages = filter (p: p.kind == "index") allPackages;
  pinnedHashes = listToAttrs (
    map (p: {
      name = p.key;
      value = map hexOf (p.entry.hashes or [ ]);
    }) indexPackages
  );
  hashesOf = pinnedHashes // purifier.buildPackages;

  # A file of an index, as a file entry of the shared purifier library, by
  # its sha256.
  fileEntry = hex: {
    path = fileName purifier.urls.${hex};
    url = purifier.urls.${hex};
    mirrors = [ ];
    hash = sriOf hex;
  };

  # The files of each package of an index whose URL the lock run found, by
  # kind. A hash without a URL is a file the index no longer serves.
  packages = builtins.mapAttrs (
    key: hashes:
    let
      names = map (hex: (fileEntry hex).path) (filter (hex: purifier.urls ? ${hex}) hashes);
      sdists = filter isSdist names;
    in
    {
      wheels = sort (a: b: a < b) (filter isWheel names);
      sdist = if sdists == [ ] then null else head sdists;
    }
  ) hashesOf;
  hasFiles = key: packages.${key}.wheels != [ ] || packages.${key}.sdist != null;

  # The packages from git and URLs, with their entries of Pipfile.lock.
  directPackages = listToAttrs (
    map (p: {
      inherit (p) name;
      value = p;
    }) (filter (p: p.kind == "git" || p.kind == "file") allPackages)
  );
  lockedSource =
    name:
    purifier.sources.${name}
      or (throw "pipenv-purifier: ${toString lockFile} has no locked source of ${name}. Run `pipenv-purifier lock`.");

  # Every locked git checkout, by its path, as a git entry of the shared
  # purifier library. The build installs a wheel it makes from the checkout,
  # so the checkout needs no .git, and the entry no commit object to rebuild
  # one.
  gitPath = p: "git/${p.name}-${p.entry.ref}";
  gitEntries = listToAttrs (
    map (p: {
      name = gitPath p;
      value = {
        path = gitPath p;
        git = {
          url = replaceStrings [ "git+" ] [ "" ] p.entry.git;
          rev = p.entry.ref;
          submodules = true;
          leaveDotGit = false;
          commitObject = null;
        };
        inherit (lockedSource p.name) hash;
      };
    }) (filter (p: p.kind == "git") (attrValues directPackages))
  );

  # The file of each package from a URL, as a file entry of the shared
  # purifier library: its hash from Pipfile.lock, or else from the lockfile.
  filePath = p: "file/${fileName p.entry.file}";
  urlFiles = listToAttrs (
    map (
      p:
      let
        listed = p.entry.hashes or [ ];
      in
      {
        name = filePath p;
        value = {
          path = filePath p;
          url = p.entry.file;
          mirrors = [ ];
          hash = if listed != [ ] then sriOf (hexOf (head listed)) else (lockedSource p.name).hash;
        };
      }
    ) (filter (p: p.kind == "file") (attrValues directPackages))
  );

  # Every locked file of an index or a URL by its path, as a file entry of
  # the shared purifier library.
  files =
    listToAttrs (
      map (hex: {
        name = (fileEntry hex).path;
        value = fileEntry hex;
      }) (attrNames purifier.urls)
    )
    // urlFiles;

  # The locked source of each package from git or a URL: the path of its
  # entry, and for a package from git, the version a backend that reads git
  # gives it.
  sources = builtins.mapAttrs (
    name: p:
    if p.kind == "git" then
      {
        artifact = gitPath p;
        version = (lockedSource name).version or null;
      }
    else
      {
        artifact = filePath p;
        version = null;
      }
  ) directPackages;

  # The local packages inside the project that Pipfile.lock names by a path
  # of a directory, by name, with their outputs: the version and whether the
  # wheel is the same on every system, from the wheel's name.
  localPackages = filter (
    p:
    p.kind == "path"
    && insideProject p.entry.path
    && builtins.readFileType (src + "/${normalizePath p.entry.path}") == "directory"
  ) allPackages;
  outputs = listToAttrs (
    map (
      p:
      let
        output =
          purifier.outputs.${p.name}
            or (throw "pipenv-purifier: ${toString lockFile} has no outputs of the local package ${p.name}. Run `pipenv-purifier lock`.");
      in
      {
        inherit (p) name;
        value = output // {
          path = normalizePath p.entry.path;
          version = elemAt (filter builtins.isString (split "-" output.wheel)) 1;
          pure = isPureWheel output.wheel;
        };
      }
    ) localPackages
  );

  # The hash the lock tool records over Pipfile.lock and the pyproject.toml
  # files of the local source trees in the project (src/pipenv_purifier.py,
  # inputs_hash).
  localPaths = map (p: p.entry.path) (filter (p: p.kind == "path") allPackages);
  treeFiles = sort (a: b: a < b) (
    unique (
      filter (f: builtins.pathExists (src + "/${f}")) (
        map (
          path:
          let
            normal = normalizePath path;
          in
          if normal == "" then "pyproject.toml" else "${normal}/pyproject.toml"
        ) (filter insideProject localPaths)
      )
    )
  );

  # What the lockfile lacks, and what it records that Pipfile.lock does not
  # list. A URL recorded for a hash that neither Pipfile.lock nor
  # `buildPackages` lists is one the lockfile was edited to name, and the
  # build refuses it before fetching anything.
  listedHashes = listToAttrs (
    map (hex: {
      name = hex;
      value = null;
    }) (concatLists (attrValues hashesOf))
  );
  problems =
    map (
      hex:
      "it has a URL for the file with sha256 ${hex}, which neither Pipfile.lock nor its build packages list"
    ) (filter (hex: !(listedHashes ? ${hex})) (attrNames purifier.urls))
    ++ map (key: "it has no files of ${key}, which Pipfile.lock pins") (
      filter (key: !hasFiles key) (unique (map (p: p.key) indexPackages))
    )
    ++ map (key: "it has no files of ${key}, which a set of build requirements needs") (
      filter (key: !(hashesOf ? ${key}) || !hasFiles key) (
        unique (concatMap (set: set.packages or [ ]) purifier.buildRequirements)
      )
    )
    ++ map (p: "it has no locked checkout of ${p.name}, which Pipfile.lock pins to a commit of git") (
      filter (p: p.kind == "git" && !(purifier.sources ? ${p.name})) (attrValues directPackages)
    );

  # The hash the lock tool records of the lockfile's own content
  # (src/pipenv_purifier.py, content_hash): the SHA-256 of the lockfile's
  # JSON without `contentHash`, as builtins.toJSON writes it.
  contentHash = hashString "sha256" (builtins.toJSON (removeAttrs purifier [ "contentHash" ]));

  inputsHash = hashString "sha256" (
    "Pipfile.lock ${hashFile "sha256" pipfileLock}\n"
    + concatStringsSep "" (map (f: "${f} ${hashFile "sha256" (src + "/${f}")}\n") treeFiles)
  );
  # Why the lockfiles cannot be used, each naming the command that fixes it.
  # Each check reads only what the checks before it found usable, so a
  # damaged lockfile gives its first problem and nothing else. A file that
  # is not JSON fails evaluation in builtins.fromJSON, with the context
  # above that names the command.
  lockProblems =
    if !builtins.pathExists pipfileLock then
      [
        "pipenv-purifier: ${toString pipfileLock} does not exist. Run `pipenv lock`, then `pipenv-purifier lock`."
      ]
    else if !builtins.pathExists lockFile then
      [ "pipenv-purifier: ${toString lockFile} does not exist. Run `pipenv-purifier lock`." ]
    else if missingFields != [ ] then
      [
        "pipenv-purifier: ${toString lockFile} is not a lockfile of this pipenv-purifier: it has no ${concatStringsSep ", " missingFields}. Run `pipenv-purifier lock`."
      ]
    else if purifier.version != supportedVersion then
      [
        "pipenv-purifier: ${toString lockFile} has lock format version ${toString purifier.version}; this library reads version ${toString supportedVersion}. Run `pipenv-purifier lock` with the version that provides this library."
      ]
    else if purifier.contentHash != contentHash then
      [
        "pipenv-purifier: ${toString lockFile} was edited after `pipenv-purifier lock` wrote it: its contentHash does not match its content. Run `pipenv-purifier lock`."
      ]
    else if purifier.inputsHash != inputsHash then
      [
        "pipenv-purifier: ${toString lockFile} does not match Pipfile.lock and the pyproject.toml files of the local packages. Run `pipenv-purifier lock`."
      ]
    else
      map (
        problem:
        "pipenv-purifier: ${toString lockFile} does not agree with Pipfile.lock: ${problem}. Run `pipenv-purifier lock`."
      ) problems;

  # The Nix systems a wheel installs on, by its platform tag, for a wheel
  # that does not install everywhere. A wheel for a platform without a Nix
  # system, such as Windows or musl, is needed on none.
  wheelSystems =
    name:
    let
      platform = builtins.elemAt (builtins.match ".*-([^-]+)\\.whl" name) 0;
      tags = filter builtins.isString (split "\\." platform);
      systemOf =
        tag:
        if builtins.match "(many)?linux.*_x86_64" tag != null then
          [ "x86_64-linux" ]
        else if builtins.match "(many)?linux.*_aarch64" tag != null then
          [ "aarch64-linux" ]
        else if builtins.match "macosx_.*_(x86_64|intel)" tag != null then
          [ "x86_64-darwin" ]
        else if builtins.match "macosx_.*_arm64" tag != null then
          [ "aarch64-darwin" ]
        else if builtins.match "macosx_.*_universal2?" tag != null then
          [
            "x86_64-darwin"
            "aarch64-darwin"
          ]
        else
          [ ];
    in
    if platform == "any" then null else unique (concatMap systemOf tags);
  withSystems =
    entry:
    let
      systems = if isWheel entry.path then wheelSystems entry.path else null;
    in
    if systems == null then entry else entry // { inherit systems; };
in
{
  # The lock in memory of the purifier contract.
  purifier = "pipenv-purifier";
  entries = map withSystems (attrValues files ++ attrValues gitEntries);
  inherit outputs;
  problems = lockProblems;

  # What the builder reads of the two lockfiles.
  views = {
    pipfileLock = pipfileLockData;
    inherit
      categories
      packagesOf
      files
      gitEntries
      packages
      sources
      outputs
      insideProject
      normalize
      normalizePath
      fileName
      ;
    inherit (purifier)
      builds
      buildRequirements
      ;
    pythonVersion = pipfileLockData._meta.requires.python_version or null;
  };
}
