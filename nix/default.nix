{ pkgs }:
{ src
  # The name of the project, used to generate derivation names
, projectName
  # The version of node to use across all project components
, nodejs ? pkgs.nodejs-18_x
  # npmlock2nix
, npmlock2nix
  # Autogenerated Nix from `spago2nix generate`
, spagoPackages ? "${src}/spago-packages.nix"
  # Extra Purescript sources to build and provide in the `devShell` as `extraSourcesDir`
, extraSources ? [ ]
, extraSourcesDir ? ".extras"
  # Data directory to add to the build and provide in the `devShell` as `dataDir`
  # E.g. [ { name = "my-data"; path = ./. ; }]
  # will be available at `data/my-data` in the `buildPursProject`s output,
, data ? [ ]
  # A directory to store `data` entries in.
, dataDir ? "data"
  # Configuration that will be used to generate a `devShell` for the project
, shell ? { }
, ...
}:
let
  inherit (pkgs) system;

  purs = pkgs.easy-ps.purs-0_15_8;

  spagoPkgs = import spagoPackages { inherit pkgs; };

  npm = import npmlock2nix { inherit pkgs; };

  projectNodeModulesSettings = {
    inherit nodejs src;
    # enables node-gyp on all packages
    sourceOverrides.buildRequirePatchShebangs = true;
    githubSourceHashMap = {
      Fourierlabs.cardano-serialization-lib-gc."fcb15e03ffb30d3a63133a7c7a447b2a6d461b09" = "sha256-PvKW1oQm2qiblTyJ6u5pMu4MwU0ZN1RnDNJYJ5O/VxQ=";
    };
  };

  projectNodeModules = npm.v2.node_modules projectNodeModulesSettings + /node_modules;

  # Constructs a development environment containing various tools to work on
  # Purescript projects. The resulting derivation can be used as a `devShell` in
  # your flake outputs
  #
  # All arguments are optional
  shellFor =
    {
      # Extra packages to include in the shell environment
      packages ? [ ]
      # Passed through to `pkgs.mkShell.inputsFrom`
    , inputsFrom ? [ ]
      # Passed through to `pkgs.mkShell.shellHook`
    , shellHook ? ""
      # One of `purs-tidy` or `purty` to format Purescript sources
    , formatter ? "purs-tidy"
      # Whether or not to include `purescript-language-server`
    , pursls ? true
      # Generated `node_modules` in the Nix store. Can be passed to have better
      # control over individual project components
    , nodeModules ? projectNodeModules
      # If `true`, all of CTL's runtime dependencies will be added to the
      # shell's `packages`. These packages are *required* if you plan on running
      # Plutip tests in your local shell environment (that is, not using Nix
      # directly as with `runPlutipTest`). Make sure you have applied
      # `overlays.runtime` or otherwise added the runtime packages to your
      # package set if you select this option!
    , withRuntime ? true
      # If `true`, the `chromium` package from your package set will be made
      # available in the shell environment. This can help with ensuring that
      # any e2e tests that you write and run with `Contract.Test.E2E` are
      # reproducible
    , withChromium ? pkgs.stdenv.isLinux
    }:
      assert pkgs.lib.assertOneOf "formatter" formatter [ "purs-tidy" "purty" ];
      with pkgs.lib;
      npm.v2.shell {
        inherit src nodejs;
        inherit packages inputsFrom;
        buildInputs = builtins.concatLists
          [
            [
              purs
              nodejs
              pkgs.easy-ps.spago
              pkgs.easy-ps.${formatter}
              pkgs.easy-ps.pscid
              pkgs.easy-ps.psa
              pkgs.easy-ps.spago2nix
              pkgs.unzip
              # Required to fix initdb locale issue in shell
              # https://github.com/Plutonomicon/cardano-transaction-lib/issues/828
              # Well, not really, as we set initdb locale to C for all cases now
              # Anyway, seems like it's good to have whole set of locales in the shell
              pkgs.glibcLocales
            ]

            (lists.optional pursls pkgs.easy-ps.purescript-language-server)

            (lists.optional withChromium pkgs.chromium)

            (
              lists.optional withRuntime (
                [
                  pkgs.ogmios
                  pkgs.plutip-server
                  pkgs.kupo
                ]
              )
            )
          ];
        shellHook = ''
          ${linkExtraSources}
          ${linkData}
        ''
        + shellHook;
        node_modules_attrs = projectNodeModulesSettings;
      };

  # Extra sources
  extra-sources = pkgs.linkFarm "extra-sources" (builtins.map (drv: { name = drv.name; path = "${drv}/src"; }) extraSources);
  hasExtraSources = builtins.length extraSources > 0;
  linkExtraSources = pkgs.lib.optionalString hasExtraSources ''
    if [ -e ./${extraSourcesDir} ]; then rm ./${extraSourcesDir}; fi
    ln -s ${extra-sources} ./${extraSourcesDir}
  '';

  # Data
  data-drv = pkgs.linkFarm "data" data;
  hasData = builtins.length data > 0;
  linkData = pkgs.lib.optionalString hasData ''
    if [ -e ./${dataDir} ]; then rm ./${dataDir}; fi
    ln -s ${data-drv} ./${dataDir}
  '';

  # Compiles the dependencies of a Purescript project and copies the `output`
  # and `.spago` directories into the Nix store.
  # Intended to be used in `buildPursProject` to not recompile the entire
  # package set every time.
  buildPursDependencies =
    {
      # Can be used to override the name given to the resulting derivation
      name ? "${projectName}-ps-deps"
      # If warnings generated from project source files will trigger a build error.
      # Controls `--strict` purescript-psa flag
    , strictComp ? true
      # Warnings from `purs` to silence during compilation, independent of `strictComp`
      # Controls `--censor-codes` purescript-psa flag
    , censorCodes ? [ "UserDefinedWarning" ]
    , ...
    }:
    pkgs.stdenv.mkDerivation {
      inherit name;
      buildInputs = [
      ];
      nativeBuildInputs = [
        spagoPkgs.installSpagoStyle
        pkgs.easy-ps.psa
        purs
        pkgs.easy-ps.spago
      ];
      # Make the derivation independent of the source files.
      # `src` is not needed
      unpackPhase = "true";
      buildPhase = ''
        install-spago-style
        psa ${pkgs.lib.optionalString strictComp "--strict" } \
          --censor-lib \
          --is-lib=.spago ".spago/*/*/src/**/*.purs" \
          --censor-codes=${builtins.concatStringsSep "," censorCodes} \
          -gsourcemaps,js
      '';
      installPhase = ''
        mkdir $out
        mv output $out/
        mv .spago $out/
      '';
    };

  # Compiles your Purescript project and copies the `output` directory into the
  # Nix store. Also copies the local sources to be made available later as `purs`
  # does not include any external files to its `output` (if we attempted to refer
  # to absolute paths from the project-wide `src` argument, they would be wrong)
  buildPursProject =
    {
      # Can be used to override the name given to the resulting derivation
      name ? projectName
      # If warnings generated from project source files will trigger a build error.
      # Controls `--strict` purescript-psa flag
    , strictComp ? true
      # Warnings from `purs` to silence during compilation, independent of `strictComp`
      # Controls `--censor-codes` purescript-psa flag
    , censorCodes ? [ "UserDefinedWarning" ]
    , pursDependencies ? buildPursDependencies {
        inherit name strictComp censorCodes;
      }
    , ...
    }:
    pkgs.stdenv.mkDerivation {
      inherit name src;
      nativeBuildInputs = [
        spagoPkgs.installSpagoStyle
        pkgs.easy-ps.psa
        purs
        pkgs.easy-ps.spago
      ];
      unpackPhase = ''
        export HOME="$TMP"
        ${linkExtraSources}
        ${linkData}

        # copy the dependency build artifacts and sources
        # preserve the modification date so that we don't rebuild them
        mkdir -p output .spago
        cp -rp ${pursDependencies}/.spago/* .spago
        cp -rp ${pursDependencies}/output/* output
        # note that we copy the entire source directory, not just $src/src,
        # because we need sources in ./examples and ./test
        cp -rp $src ./src

        # add write permissions for the PS compiler to use
        # `output/cache-db.json`
        chmod -R +w output/
      '';
      buildPhase = ''
        psa ${pkgs.lib.optionalString strictComp "--strict" } \
          --censor-lib \
          --is-lib=.spago ".spago/*/*/src/**/*.purs" ${pkgs.lib.optionalString hasExtraSources ''--is-lib=./${extraSourcesDir} "${extraSourcesDir}/*/**/*.purs"''} \
          --censor-codes=${builtins.concatStringsSep "," censorCodes} "./src/**/*.purs" \
          -gsourcemaps,js
      '';
      # We also need to copy all of `src` here, since compiled modules in `output`
      # might refer to paths that will point to nothing if we use `src` directly
      # in other derivations (e.g. when using `fs.readFileSync` inside an FFI
      # module)
      installPhase = ''
        mkdir $out
        cp -r output $out/
        ${pkgs.lib.optionalString hasExtraSources ''cp -r ./${extraSourcesDir} $out/''}
        ${pkgs.lib.optionalString hasData ''cp -r ./${dataDir} $out/''}
      '';
    };

  # Runs a test written in Purescript using NodeJS.
  runPursTest =
    {
      # The main Purescript module
      testMain
      # The entry point function in the main PureScript module
    , psEntryPoint ? "main"
      # Can be used to override the name of the resulting derivation
    , name ? "${projectName}-check"
      # Generated `node_modules` in the Nix store. Can be passed to have better
      # control over individual project components
    , nodeModules ? projectNodeModules
      # Additional variables to pass to the test environment
    , env ? { }
      # Passed through to the `buildInputs` of the derivation. Use this to add
      # additional packages to the test environment
    , buildInputs ? [ ]
    , builtProject ? buildPursProject { main = testMain; }
    , ...
    }: pkgs.runCommand "${name}"
      (
        {
          inherit src;
          nativeBuildInputs = [ builtProject nodeModules ] ++ buildInputs;
        } // env
      )
      ''
        # Copy the purescript project files
        cp -r ${builtProject}/* .

        # The tests may depend on sources
        cp -r $src/* .

        # Provide NPM dependencies to the test suite scripts
        ln -sfn ${nodeModules} node_modules

        # Call the main module and execute the entry point function
        ${nodejs}/bin/node --enable-source-maps -e 'import("./output/${testMain}/index.js").then(m => m.${psEntryPoint}())'

        # Create output file to tell Nix we succeeded
        touch $out
      '';

  # Runs a test using Plutip. Takes the same arguments as `runPursTest`
  #
  # NOTE: You *must* either use CTL's `overlays.runtime` or otherwise make the
  # the following required `buildInputs` available in your own package set:
  #
  #  - `ogmios`
  #  - `kupo`
  #  - `plutip-server`
  #
  runPlutipTest =
    args:
    runPursTest (
      args // {
        buildInputs = with pkgs; [
          ogmios
          plutip-server
          kupo
        ]
        ++ (args.buildInputs or [ ]);
      }
    );

  runE2ETest =
    {
      # The name of the main Purescript module for the runner
      runnerMain
      # Entry point function of the `runnerMain` module
    , runnerPsEntryPoint ? "main"
      # The name of the test module that will be bundled and served via a
      # webserver
    , testMain
      # Environment file with E2E test definitions, relative to `src`
    , envFile ? "test/e2e-ci.env"
      # A file with empty settings for chromium, relative to `src`
    , emptySettingsFile ? "test-data/empty-settings.tar.gz"
    , testTimeout ? 200
      # Can be used to override the name of the resulting derivation
    , name ? "${projectName}-e2e"
      # Generated `node_modules` in the Nix store. Can be passed to have better
      # control over individual project components
    , nodeModules ? projectNodeModules
      # Additional variables to pass to the test environment
    , env ? { }
      # Passed through to the `buildInputs` of the derivation. Use this to add
      # additional packages to the test environment
    , buildInputs ? [ ]
    , bundledPursProject ? (bundlePursProjectWebpack {
        main = testMain;
      })
    , builtRunnerProject ? (buildPursProject {
        main = runnerMain;
      })
    , ...
    }@args:
    let
      # We need fonts if we are going to use chromium
      etc_fonts =
        let
          fonts = with pkgs; [
            dejavu_fonts
            freefont_ttf
            liberation_ttf
          ];
          cache = pkgs.makeFontsCache { inherit (pkgs) fontconfig; fontDirectories = fonts; };
          config = pkgs.writeTextDir "conf.d/00-nixos-cache.conf" ''<?xml version='1.0'?>
            <!DOCTYPE fontconfig SYSTEM 'urn:fontconfig:fonts.dtd'>
            <fontconfig>
              ${builtins.concatStringsSep "\n" (map (font: "<dir>${font}</dir>") fonts)}
              <cachedir>${cache}</cachedir>
            </fontconfig>
          '';
        in
        pkgs.buildEnv { name = "etc-fonts"; paths = [ "${pkgs.fontconfig.out}/etc/fonts" config ]; };
      # We use bubblewrap to populate /etc/fonts.
      # We use ungoogled-chromium because chromium some times times out on Hydra.
      #
      # Chromium wrapper code was provided to us by Las Safin (thanks)
      chromium = pkgs.writeShellScriptBin "chromium" ''
        env - ${pkgs.bubblewrap}/bin/bwrap \
          --unshare-all \
          --share-net \
          --ro-bind /nix/store /nix/store \
          --bind /build /build \
          --uid 1000 \
          --gid 1000 \
          --proc /proc \
          --dir /tmp \
          --dev /dev \
          --setenv TMPDIR /tmp \
          --setenv XDG_RUNTIME_DIR /tmp \
          --bind . /data \
          --chdir /data  \
          --ro-bind ${etc_fonts} /etc/fonts \
          -- ${pkgs.ungoogled-chromium}/bin/chromium \
            --no-sandbox \
            --disable-setuid-sandbox \
            --disable-gpu \
            "$@"
      '';
    in
    pkgs.runCommand "${name}"
      ({
        inherit src;
        nativeBuildInputs = with pkgs; [
          builtRunnerProject
          bundledPursProject
          nodeModules
          ogmios
          kupo
          plutip-server
          chromium
          python38 # To serve bundled CTL
          # Utils needed by E2E test code
          which # used to check for browser availability
          gnutar # used unpack settings archive within E2E test code
          curl # used to query for the web server to start (see below)
        ] ++ (args.buildInputs or [ ]);
      } // env)
      ''
        chmod -R +rw .

        # Load the test definitions from file
        source $src/${envFile}

        export E2E_SETTINGS_ARCHIVE="$src/${emptySettingsFile}"
        export E2E_CHROME_USER_DATA="./test-data/chrome-user-data"
        export E2E_TEST_TIMEOUT=${toString testTimeout}
        export E2E_BROWSER=${chromium}/bin/chromium # use custom bwrap-ed chromium
        export E2E_NO_HEADLESS=false
        export PLUTIP_PORT=8087
        export OGMIOS_PORT=1345
        export E2E_EXTRA_BROWSER_ARGS="--disable-web-security"

        # Move bundle files to the served dir
        mkdir -p serve
        cp -r ${bundledPursProject}/* serve/

        # Create an HTML that just serves entry point to the bundle
        cat << EOF > serve/index.html
        <!DOCTYPE html>
        <html>
          <body><script type="module" src="./index.js"></script></body>
        </html>
        EOF

        # Launch a webserver and wait for the content to become available
        python -m http.server 4008 --directory serve 2>/dev/null &
        until curl -S http://127.0.0.1:4008/index.html &>/dev/null; do
          echo "Trying to connect to webserver...";
          sleep 0.1;
        done;

        ln -sfn ${nodeModules} node_modules

        cp -r ${builtRunnerProject}/output .
        cp -r $src/* .
        chmod -R +rw .

        ${nodejs}/bin/node \
          --enable-source-maps \
          -e 'import("./output/${runnerMain}/index.js").then(m => m.${runnerPsEntryPoint}())' \
          e2e-test run

        mkdir $out
      ''
  ;

  # Bundles a Purescript project using esbuild, typically for the browser
  bundlePursProjectEsbuild =
    {
      # Can be used to override the name given to the resulting derivation
      name ? "${projectName}-bundle-" +
        (if browserRuntime then "web" else "nodejs")
      # The main Purescript module
    , main
      # The entry point function in the main PureScript module
    , psEntryPoint ? "main"
      # Whether this bundle is being produced for a browser environment or not
    , browserRuntime ? true
    , esbuildBundleScript ? "esbuild/bundle.js"
      # Generated `node_modules` in the Nix store. Can be passed to have better
      # control over individual project components
    , nodeModules ? projectNodeModules
    , builtProject ? buildPursProject { inherit main; }
    , ...
    }: pkgs.runCommand "${name}"
      {
        inherit src;
        buildInputs = [
          nodejs
          nodeModules
        ];
        nativeBuildInputs = [
          purs
          pkgs.easy-ps.spago
          builtProject
        ];
      }
      ''
        export HOME="$TMP"
        ln -sfn ${nodeModules} node_modules
        export PATH="${nodeModules}/.bin:$PATH"
        ${pkgs.lib.optionalString browserRuntime "export BROWSER_RUNTIME=1"}
        cp -r ${builtProject}/* .
        cp -r $src/* .
        chmod -R +rw .
        echo 'import("./output/${main}/index.js").then(m => m.${psEntryPoint}());' > entrypoint.js
        mkdir $out
        node ${esbuildBundleScript} ./entrypoint.js $out/index.js
      '';

  # Bundles a Purescript project using Webpack, typically for the browser
  bundlePursProjectWebpack =
    {
      # Can be used to override the name given to the resulting derivation
      name ? "${projectName}-bundle-" +
        (if browserRuntime then "web" else "nodejs")
      # The main Purescript module
    , main
      # The entry point function in the main PureScript module
    , psEntryPoint ? "main"
      # If this bundle is being produced for a browser environment or not
    , browserRuntime ? true
      # Path to the Webpack config to use
    , webpackConfig ? "webpack.config.cjs"
      # The name of the bundled JS module that `spago bundle-module` will produce
    , bundledModuleName ? "output.js"
      # Generated `node_modules` in the Nix store. Can be passed to have better
      # control over individual project components
    , nodeModules ? projectNodeModules
      # If the spago bundle-module output should be included in the derivation
    , includeBundledModule ? false
    , builtProject ? buildPursProject { inherit main; }
    , ...
    }: pkgs.runCommand "${name}"
      {
        inherit src;
        buildInputs = [
        ];
        nativeBuildInputs = [
          nodejs
          nodeModules
          builtProject
          purs
          pkgs.easy-ps.spago
        ];
      }
      ''
        export HOME="$TMP"
        export PATH="${nodeModules}/.bin:$PATH"
        ${pkgs.lib.optionalString browserRuntime "export BROWSER_RUNTIME=1"}
        cp -r ${builtProject}/* .
        cp -r $src/* .
        chmod -R +rw .
        mkdir -p ./dist
        echo 'import("./output/${main}/index.js").then(m => m.${psEntryPoint}());' > entrypoint.js
        ${pkgs.lib.optionalString includeBundledModule "cp ${bundledModuleName} ./dist"}
        mkdir $out
        webpack --mode=production -c ${webpackConfig} -o $out/ \
          --entry ./entrypoint.js
      '';

  buildPursDocs =
    { name ? "${projectName}-docs"
    , format ? "html"
    , ...
    }@args:
    (buildPursProject (args // { strictComp = false; })).overrideAttrs
      (oas: {
        inherit name;
        buildPhase = ''
          purs docs --format ${format} "./src/**/*.purs" ".spago/*/*/src/**/*.purs" ${pkgs.lib.optionalString hasExtraSources ''"${extraSourcesDir}/*/**/*.purs"''}
        '';
        installPhase = ''
          mkdir $out
          cp -r generated-docs $out
          cp -r output $out
        '';
      });

in
{
  inherit
    buildPursProject buildPursDependencies runPursTest runPlutipTest runE2ETest
    bundlePursProjectEsbuild bundlePursProjectWebpack
    buildPursDocs
    # TODO: restore buildSearchablePursDocs and launchSearchablePursDocs
    # https://github.com/Plutonomicon/cardano-transaction-lib/issues/1578
    purs nodejs;
  devShell = shellFor shell;
  compiled = buildPursProject { };
  nodeModules = projectNodeModules;
}
