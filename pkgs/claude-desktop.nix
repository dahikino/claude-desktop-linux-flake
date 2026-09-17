{
  lib,
  stdenvNoCC,
  fetchurl,
  electron,
  p7zip,
  icoutils,
  imagemagick,
  nodejs,
  asar,
  makeDesktopItem,
  python3,
  bash,
  getent,
  node-pty,
  perl,
}:
let
  pname = "claude-desktop";
  version = "2.110.1";

  # Anthropic stopped serving the Squirrel .exe wrapper at predictable URLs
  # for newer versions; the .nupkg is now hosted directly under
  # AnthropicClaude-${version}-full.nupkg. We wrap it back into a zip in the
  # buildPhase so the upstream build.sh (which expects a Squirrel exe) keeps
  # working unchanged.
  srcs = {
    x86_64-linux = fetchurl {
      url = "https://downloads.claude.ai/releases/win32/x64/AnthropicClaude-${version}-full.nupkg";
      hash = "sha256-DsfofxMm7MHX5fMYjBqbWCilo2y4luds3X4IcTaftTE=";
    };
    aarch64-linux = fetchurl {
      url = "https://downloads.claude.ai/releases/win32/arm64/AnthropicClaude-${version}-full.nupkg";
      hash = lib.fakeHash;
    };
  };

  srcExe = srcs.${stdenvNoCC.hostPlatform.system} or (throw "Unsupported system: ${stdenvNoCC.hostPlatform.system}");

  sourceRoot = lib.cleanSourceWith {
    src = ./..;
    filter = path: type:
      let rel = lib.removePrefix (toString ./.. + "/") path;
      in !(lib.hasPrefix "result" rel)
      && !(lib.hasPrefix ".git" rel);
  };

  # The unwrapped electron derivation — contains the real ELF binary
  electronUnwrapped = electron.passthru.unwrapped or electron;
  electronDir = "${electronUnwrapped}/libexec/electron";

  desktopItem = makeDesktopItem {
    name = "claude-desktop";
    exec = "claude-desktop %u";
    icon = "claude-desktop";
    type = "Application";
    terminal = false;
    desktopName = "Claude";
    genericName = "Claude Desktop";
    startupWMClass = "Claude";
    categories = [ "Office" "Utility" ];
    mimeTypes = [ "x-scheme-handler/claude" ];
  };
in
stdenvNoCC.mkDerivation {
  inherit pname version;

  src = srcExe;

  nativeBuildInputs = [
    p7zip
    nodejs
    asar
    icoutils
    imagemagick
    bash
    python3
    getent
    # build.sh s'appuie sur perl -0pi pour les substitutions multiligne à
    # backreferences (délai DBus du tray, fallback getHostPlatform). Absent du
    # sandbox jusqu'ici : le délai DBus était silencieusement sauté en 1.32885.1
    # (perl: command not found), alors que le même code passait hors sandbox.
    perl
  ];

  # The exe is not a standard archive — use manual unpack
  dontUnpack = true;
  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    export HOME=$TMPDIR

    # build.sh expects a Squirrel .exe whose 7z extraction yields a
    # top-level AnthropicClaude-*.nupkg. Anthropic now ships the .nupkg
    # directly, so we wrap it in a tarball (zip-in-zip wrapping with 7z
    # auto-merges contents — tar avoids that). 7z auto-detects the tar
    # format on extraction, so Claude-Setup.exe being a tar is fine.
    mkdir -p nupkg-wrapper
    cp $src nupkg-wrapper/AnthropicClaude-${version}-full.nupkg
    ( cd nupkg-wrapper && tar -cf ../Claude-Setup.exe \
        AnthropicClaude-${version}-full.nupkg )

    # Run build.sh — handles extraction, patching, icon extraction, asar repacking
    # sourceRoot points to the flake repo (contains scripts/)
    bash ${sourceRoot}/scripts/build.sh \
      --exe "$(pwd)/Claude-Setup.exe" \
      --source-dir "${sourceRoot}" \
      --node-pty-dir "${node-pty}/lib/node_modules/node-pty" \
      --build nix \
      --clean no

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    #==========================================================================
    # Create a custom Electron tree with app resources co-located.
    #
    # Chromium computes process.resourcesPath from /proc/self/exe, so it
    # always points to electron-unwrapped's resources/ dir. When
    # ELECTRON_FORCE_IS_PACKAGED=true, the app reads en-US.json from
    # resourcesPath at module load time, causing an ENOENT crash.
    #
    # Solution: copy the Electron ELF binary into our own tree so that
    # /proc/self/exe resolves here, then merge resources.
    #==========================================================================
    electron_tree=$out/lib/claude-desktop/electron

    mkdir -p $electron_tree/resources

    # Copy the ELF binary — MUST be a real copy (not symlink) so
    # /proc/self/exe resolves to our tree
    cp ${electronDir}/electron $electron_tree/electron

    # Symlink everything else from electron-unwrapped
    for item in ${electronDir}/*; do
      name=$(basename "$item")
      [[ "$name" = "electron" ]] && continue
      [[ "$name" = "resources" ]] && continue
      ln -s "$item" "$electron_tree/$name"
    done

    # Populate resources/ — start with Electron's own (default_app.asar)
    for item in ${electronDir}/resources/*; do
      ln -s "$item" "$electron_tree/resources/$(basename "$item")"
    done

    # Install app.asar and unpacked resources into the merged tree
    cp build/electron-app/app.asar $electron_tree/resources/
    cp -r build/electron-app/app.asar.unpacked $electron_tree/resources/

    # Install tray icons into resources
    for tray_icon in build/electron-app/nix-resources/Tray*; do
      [[ -f "$tray_icon" ]] && cp "$tray_icon" $electron_tree/resources/
    done

    # Install SSH helpers into resources
    if [[ -d build/electron-app/nix-resources/claude-ssh ]]; then
      cp -r build/electron-app/nix-resources/claude-ssh \
        $electron_tree/resources/
    fi

    # Install cowork resources (smol-bin, plugin shim)
    for cowork_res in build/electron-app/nix-resources/smol-bin.*.vhdx \
                      build/electron-app/nix-resources/cowork-plugin-shim.sh; do
      if [[ -f "$cowork_res" ]]; then
        cp "$cowork_res" $electron_tree/resources/
        echo "Installed cowork resource: $(basename "$cowork_res")"
      fi
    done

    # Install locale JSON files into resources
    for locale_json in build/claude-extract/lib/net45/resources/*-*.json; do
      [[ -f "$locale_json" ]] \
        && cp "$locale_json" $electron_tree/resources/
    done

    # Create the electron wrapper — replicates env setup from stock
    # electron wrapper, then execs our custom binary
    head -n -1 ${electron}/bin/electron > $electron_tree/electron-wrapper
    echo "exec \"$electron_tree/electron\" \"\$@\"" >> $electron_tree/electron-wrapper
    chmod +x $electron_tree/electron-wrapper

    # Update CHROME_DEVEL_SANDBOX to point to our tree's chrome-sandbox
    substituteInPlace $electron_tree/electron-wrapper \
      --replace-quiet "${electron}/libexec/electron/chrome-sandbox" \
        "$electron_tree/chrome-sandbox"

    #==========================================================================
    # Standard install (icons, desktop file, launcher)
    #==========================================================================

    # Convenience symlink for resources dir
    ln -s $electron_tree/resources $out/lib/claude-desktop/resources

    # Install icons
    for size in 16 24 32 48 64 256; do
      icon_dir=$out/share/icons/hicolor/"$size"x"$size"/apps
      mkdir -p "$icon_dir"
      icon=$(find build/ -name "claude_*''${size}x''${size}x32.png" 2>/dev/null | head -1)
      if [[ -n "$icon" ]]; then
        install -Dm644 "$icon" "$icon_dir/claude-desktop.png"
      fi
    done

    # Install shared launcher library
    install -Dm755 ${sourceRoot}/scripts/launcher-common.sh \
      $out/lib/claude-desktop/launcher-common.sh

    # Install .desktop file
    mkdir -p $out/share/applications
    install -Dm644 ${desktopItem}/share/applications/* $out/share/applications/

    # Create launcher script
    mkdir -p $out/bin
    cat > $out/bin/claude-desktop <<'LAUNCHER'
#!/usr/bin/env bash
# Claude Desktop launcher for NixOS

electron_exec="ELECTRON_PLACEHOLDER"
app_path="RESOURCES_PLACEHOLDER/app.asar"

source "LAUNCHER_LIB_PLACEHOLDER"

# Handle --doctor flag
if [[ "''${1:-}" == '--doctor' ]]; then
	run_doctor "$electron_exec"
	exit $?
fi

# Setup logging and environment
setup_logging || exit 1
setup_electron_env
cleanup_orphaned_cowork_daemon
cleanup_stale_lock
cleanup_stale_cowork_socket

log_message '--- Claude Desktop Launcher Start (NixOS) ---'
log_message "Timestamp: $(date)"
log_message "Arguments: $@"

if ! check_display; then
	log_message 'No display detected (TTY session)'
	echo 'Error: Claude Desktop requires a graphical desktop environment.' >&2
	exit 1
fi

detect_display_backend
build_electron_args 'nix'
electron_args+=("$app_path")

log_message "Executing: $electron_exec ''${electron_args[*]} $*"
"$electron_exec" "''${electron_args[@]}" "$@" >> "$log_file" 2>&1
exit_code=$?
log_message "Electron exited with code: $exit_code"
exit $exit_code
LAUNCHER
    substituteInPlace $out/bin/claude-desktop \
      --replace-fail "ELECTRON_PLACEHOLDER" "$electron_tree/electron-wrapper" \
      --replace-fail "RESOURCES_PLACEHOLDER" "$electron_tree/resources" \
      --replace-fail "LAUNCHER_LIB_PLACEHOLDER" "$out/lib/claude-desktop/launcher-common.sh"
    chmod +x $out/bin/claude-desktop

    runHook postInstall
  '';

  meta = with lib; {
    description = "Claude Desktop for Linux";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "claude-desktop";
  };
}
