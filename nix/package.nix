# Impure by design: Xcode isn't in nixpkgs, so this needs it at `xcode` and the sandbox off or relaxed.
{
  lib,
  stdenvNoCC,
  xcode ? "/Applications/Xcode.app",
}:

let
  projectYml = builtins.readFile ../project.yml;
  version = builtins.head (builtins.match ''.*MARKETING_VERSION: "([0-9.]+)".*'' projectYml);
  arch = if stdenvNoCC.hostPlatform.isAarch64 then "arm64" else "x86_64";
in
stdenvNoCC.mkDerivation {
  pname = "tinycast";
  inherit version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Tinycast
      ../Tinycast.xcodeproj
      ../NOTICE.md
    ];
  };

  # Lets a relaxed sandbox reach Xcode and the system tools xcodebuild shells out to.
  __noChroot = true;

  # Fixup would strip or patch Mach-O files, and either breaks the code signature.
  dontFixup = true;

  buildPhase = ''
    runHook preBuild

    # nixpkgs' darwin environment points the compiler at its own SDK; Xcode must pick its own.
    unset SDKROOT MACOSX_DEPLOYMENT_TARGET NIX_CFLAGS_COMPILE NIX_LDFLAGS LD CC CXX
    export DEVELOPER_DIR="${xcode}/Contents/Developer"
    export PATH="$DEVELOPER_DIR/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"

    if [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
      echo "error: Tinycast builds with Xcode, and none was found at ${xcode}." >&2
      echo "Install Xcode there, or override the package with { xcode = \"/path/to/Xcode.app\"; }." >&2
      exit 1
    fi

    # Ad-hoc, since no signing key belongs in the store; the macro server can't sandbox as nixbld.
    xcodebuild \
      -project Tinycast.xcodeproj -scheme Tinycast -configuration Release \
      -derivedDataPath "$TMPDIR/DerivedData" \
      ARCHS=${arch} ONLY_ACTIVE_ARCH=NO \
      CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
      TINYCAST_PACKAGED_BY=nix \
      'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox' \
      COMPILER_INDEX_STORE_ENABLE=NO \
      build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/Applications"
    /usr/bin/ditto "$TMPDIR/DerivedData/Build/Products/Release/Tinycast.app" "$out/Applications/Tinycast.app"
    /usr/bin/codesign --verify --strict --deep "$out/Applications/Tinycast.app"
    runHook postInstall
  '';

  meta = {
    description = "Native macOS launcher with encrypted clipboard history (domwst fork)";
    homepage = "https://github.com/domwst/tinycast";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
}
