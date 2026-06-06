#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${HOME}/Applications/CONFABULATOR.app"
OUTPUT_DIR="${ROOT_DIR}/build/installer"
VERSION="${CONFABULATOR_VERSION:-0.1.0}"
IDENTIFIER="${CONFABULATOR_BUNDLE_ID:-com.matdryhurst.confabulator}"
INSTALLER_IDENTITY="${CONFABULATOR_INSTALLER_IDENTITY:-}"
NOTARY_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-notarytool-creds}"
SKIP_BUILD=0
NOTARIZE=0

print_help() {
  cat <<'EOF'
Create a double-click macOS installer for CONFABULATOR.

Usage:
  scripts/package_confabulator_pkg.sh [options]

Options:
  --skip-build                 Package the existing app without rebuilding.
  --app PATH                   App bundle to package. Default: ~/Applications/CONFABULATOR.app
  --output-dir PATH            Folder for CONFABULATOR.pkg. Default: build/installer
  --version VERSION            Package version. Default: 0.1.0 or CONFABULATOR_VERSION
  --identifier ID              Package identifier. Default: com.matdryhurst.confabulator
  --sign "IDENTITY"            Sign the installer with a Developer ID Installer identity.
  --notarize                   Submit the signed installer to Apple and staple the ticket.
  --keychain-profile NAME      notarytool profile. Default: notarytool-creds
  -h, --help                   Show this help.

Environment:
  MAGENTART_DEVELOPER_ID          Developer ID Application identity for the app build.
  CONFABULATOR_INSTALLER_IDENTITY Developer ID Installer identity for this .pkg.
  NOTARYTOOL_KEYCHAIN_PROFILE     Stored notarytool profile name.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --app)
      APP_PATH="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --identifier)
      IDENTIFIER="$2"
      shift 2
      ;;
    --sign)
      INSTALLER_IDENTITY="$2"
      shift 2
      ;;
    --notarize)
      NOTARIZE=1
      shift
      ;;
    --keychain-profile)
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      print_help >&2
      exit 2
      ;;
  esac
done

need_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

find_cmake() {
  if [[ -x "${ROOT_DIR}/.venv-build/bin/cmake" ]]; then
    echo "${ROOT_DIR}/.venv-build/bin/cmake"
  elif command -v cmake >/dev/null 2>&1; then
    command -v cmake
  else
    echo "cmake"
  fi
}

need_tool pkgbuild
need_tool xcrun
need_tool ditto

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  CMAKE_BIN="$(find_cmake)"
  if ! command -v "${CMAKE_BIN}" >/dev/null 2>&1 && [[ ! -x "${CMAKE_BIN}" ]]; then
    cat >&2 <<'EOF'
Could not find CMake.

Run:
  uv venv --python 3.12 .venv-build
  source .venv-build/bin/activate
  uv pip install "cmake<3.28"

Then run this script again.
EOF
    exit 1
  fi

  JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"
  echo "Building CONFABULATOR..."
  "${CMAKE_BIN}" . -B build
  "${CMAKE_BIN}" --build build --target deploy_mrt2_collider -j"${JOBS}"
fi

if [[ ! -d "${APP_PATH}" ]]; then
  cat >&2 <<EOF
Could not find ${APP_PATH}

Build the app first:
  cmake --build build --target deploy_mrt2_collider -j10

Or pass a bundle path:
  scripts/package_confabulator_pkg.sh --app /path/to/CONFABULATOR.app --skip-build
EOF
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
PKG_PATH="${OUTPUT_DIR}/CONFABULATOR.pkg"
STAGING_DIR="${OUTPUT_DIR}/pkg-staging"
STAGED_APP="${STAGING_DIR}/CONFABULATOR.app"
rm -f "${PKG_PATH}"
rm -rf "${STAGING_DIR}"
mkdir -p "${STAGING_DIR}"

echo "Staging a clean app bundle..."
ditto --norsrc "${APP_PATH}" "${STAGED_APP}"
xattr -cr "${STAGED_APP}" >/dev/null 2>&1 || true

PKGBUILD_ARGS=(
  --component "${STAGED_APP}"
  --install-location /Applications
  --identifier "${IDENTIFIER}"
  --version "${VERSION}"
  --filter '(^|/)\._[^/]*$'
  --filter '(^|/)\.DS_Store$'
)

if [[ -n "${INSTALLER_IDENTITY}" ]]; then
  PKGBUILD_ARGS+=(--sign "${INSTALLER_IDENTITY}")
fi

echo "Packaging ${APP_PATH}"
pkgbuild "${PKGBUILD_ARGS[@]}" "${PKG_PATH}"
rm -rf "${STAGING_DIR}"

if [[ "${NOTARIZE}" -eq 1 ]]; then
  if [[ -z "${INSTALLER_IDENTITY}" ]]; then
    cat >&2 <<'EOF'
--notarize requires a signed installer.

Pass:
  --sign "Developer ID Installer: Your Name (TEAMID)"

The app itself must also be built with a Developer ID Application identity:
  export MAGENTART_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
EOF
    exit 1
  fi

  echo "Submitting installer to Apple notarization..."
  xcrun notarytool submit "${PKG_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

  echo "Stapling notarization ticket..."
  xcrun stapler staple "${PKG_PATH}"
  xcrun stapler validate "${PKG_PATH}"
fi

echo
echo "Created: ${PKG_PATH}"
echo
if [[ -z "${INSTALLER_IDENTITY}" ]]; then
  cat <<'EOF'
This installer is unsigned. It is useful for testing, but macOS may warn users.
For the smooth public-download version, rebuild with Developer ID signing and notarization.
EOF
fi
