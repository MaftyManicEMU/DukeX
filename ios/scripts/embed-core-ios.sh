#!/usr/bin/env bash
set -euo pipefail

if [[ "${PLATFORM_NAME:-}" == iphonesimulator* ]]; then
  echo "Skipping iOS core embed for simulator builds."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
CORE_DYLIB="${XEMU_IOS_CORE_DYLIB:-${SOURCE_DIR}/build-ios-arm64/libxemu-ios-core.dylib}"
SLIRP_DYLIB="${XEMU_IOS_SLIRP_DYLIB:-${SOURCE_DIR}/build-ios-arm64/subprojects/slirp/libslirp.0.dylib}"
MOLTENVK_FRAMEWORK="${MOLTENVK_FRAMEWORK:-}"
CORE_SLOT_COUNT="${XEMU_IOS_CORE_SLOT_COUNT:-3}"

if [[ ! -f "${CORE_DYLIB}" ]]; then
  cat >&2 <<EOF
Missing iOS core dylib:
  ${CORE_DYLIB}

Build it first from the no-space workspace:
  ios/scripts/build-core-ios.sh
EOF
  exit 1
fi

if [[ ! -f "${SLIRP_DYLIB}" ]]; then
  cat >&2 <<EOF
Missing iOS Slirp dylib:
  ${SLIRP_DYLIB}

Build the iOS core with NAT support first:
  ios/scripts/build-core-ios.sh
EOF
  exit 1
fi

FRAMEWORKS_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
DESTINATION="${FRAMEWORKS_DIR}/libxemu-ios-core.dylib"
SLIRP_DESTINATION="${FRAMEWORKS_DIR}/libslirp.0.dylib"
MOLTENVK_DESTINATION="${FRAMEWORKS_DIR}/MoltenVK.framework"
CORE_SLOT_DESTINATIONS=()

mkdir -p "${FRAMEWORKS_DIR}"
cp "${CORE_DYLIB}" "${DESTINATION}"
chmod 755 "${DESTINATION}"
for slot in $(seq 0 $((CORE_SLOT_COUNT - 1))); do
  SLOT_DESTINATION="${FRAMEWORKS_DIR}/libxemu-ios-core-slot${slot}.dylib"
  cp "${CORE_DYLIB}" "${SLOT_DESTINATION}"
  chmod 755 "${SLOT_DESTINATION}"
  /usr/bin/install_name_tool -id "@rpath/libxemu-ios-core-slot${slot}.dylib" "${SLOT_DESTINATION}"
  CORE_SLOT_DESTINATIONS+=("${SLOT_DESTINATION}")
done
cp "${SLIRP_DYLIB}" "${SLIRP_DESTINATION}"
chmod 755 "${SLIRP_DESTINATION}"

if [[ -z "${MOLTENVK_FRAMEWORK}" || ! -d "${MOLTENVK_FRAMEWORK}" ]]; then
  cat >&2 <<EOF
Missing MoltenVK iOS framework:
  ${MOLTENVK_FRAMEWORK:-<unset>}

Set MOLTENVK_FRAMEWORK to the ios-arm64 MoltenVK.framework.
EOF
  exit 1
fi

rm -rf "${MOLTENVK_DESTINATION}"
/usr/bin/ditto "${MOLTENVK_FRAMEWORK}" "${MOLTENVK_DESTINATION}"
chmod 755 "${MOLTENVK_DESTINATION}/MoltenVK"

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" &&
      -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" &&
      "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]]; then
	  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
	    --timestamp=none "${DESTINATION}"
	  for CORE_DESTINATION in "${CORE_SLOT_DESTINATIONS[@]}"; do
	    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
	      --timestamp=none "${CORE_DESTINATION}"
	  done
	  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
	    --timestamp=none "${SLIRP_DESTINATION}"
	  /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
	    --timestamp=none "${MOLTENVK_DESTINATION}"
fi
