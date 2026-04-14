#!/usr/bin/env bash
set -euo pipefail

readonly FIELD_SEP=$'\x1f'
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"; readonly REPO_ROOT
readonly WORKSPACE_DIR="${REPO_ROOT}/.zmk-workspace"
readonly WORKSPACE_CONFIG_DIR="${WORKSPACE_DIR}/config"
readonly DIST_DIR="${REPO_ROOT}/dist"
readonly WEST_MANIFEST_FILE="${REPO_ROOT}/config/west.yml"
readonly WEST_UPDATE_MARKER="${WORKSPACE_DIR}/.west_update_marker"
readonly PRISTINE="${PRISTINE:-auto}"

DO_UPDATE=0
LIST_ONLY=0
ENABLE_LOGGING=0
ACTION="build"
REQUESTED_ARTIFACTS=()
SDK_COMPAT_PATCH_ACTIVE=0

usage() {
  cat <<'EOF'
Usage: ./scripts/build-local.sh [options] [artifact-name ...]

Builds this repo's ZMK firmware using .zmk-workspace as the west workspace.

Options:
  --logging              Enable the zmk-usb-logging snippet for builds.
  --list                 Show artifact names from build.yaml and exit.
  --update               Run west update before building.
  --pristine MODE        Pass pristine mode to west build (auto|always|never).
  -h, --help             Show this help.

Commands:
  clean                  Remove local build outputs from .zmk-workspace/build and dist/.
  purge                  Remove .zmk-workspace and dist/.
  update                 Run west update if needed and exit.

Examples:
  ./scripts/build-local.sh
  ./scripts/build-local.sh --logging crosses_54_left
  ./scripts/build-local.sh crosses_54_left crosses_54_right
  ./scripts/build-local.sh clean
  ./scripts/build-local.sh --update --pristine always
EOF
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

have_tool() {
  command -v "$1" >/dev/null 2>&1
}

BUILD_ROWS=()

load_build_rows() {
  mapfile -t BUILD_ROWS < <(
    # shellcheck disable=SC2016
    yq -r --arg field_sep "${FIELD_SEP}" '
      .include[] |
      [
        (.["artifact-name"] // (.shield + "-" + .board + "-zmk")),
        .board,
        .shield,
        (.snippet // ""),
        (.["cmake-args"] // "")
      ] | join($field_sep)
    ' "${REPO_ROOT}/build.yaml"
  )
}

list_artifacts() {
  local row
  for row in "${BUILD_ROWS[@]}"; do
    printf '%s\n' "${row%%"${FIELD_SEP}"*}"
  done
}

sync_config_dir() {
  mkdir -p "${WORKSPACE_CONFIG_DIR}"

  if have_tool rsync; then
    rsync -a --delete "${REPO_ROOT}/config/" "${WORKSPACE_CONFIG_DIR}/"
    return
  fi

  local path name
  shopt -s dotglob nullglob
  for path in "${WORKSPACE_CONFIG_DIR}"/*; do
    name="${path##*/}"
    [[ -e "${REPO_ROOT}/config/${name}" ]] || rm -rf -- "${path}"
  done

  for path in "${REPO_ROOT}/config"/*; do
    name="${path##*/}"
    rm -rf -- "${WORKSPACE_CONFIG_DIR:?}/${name}"
    cp -a -- "${path}" "${WORKSPACE_CONFIG_DIR}/"
  done
  shopt -u dotglob nullglob
}

normalize_west_config() {
  (
    cd "${WORKSPACE_DIR}"
    west config manifest.path config
    west config manifest.file west.yml
    west config zephyr.base zephyr
  )
}

patch_pmw3610_binding() {
  local binding_path="${WORKSPACE_DIR}/zmk-pmw3610-driver/dts/bindings/pixart,pmw3610.yml"

  if [[ -f "${binding_path}" ]] \
    && grep -q 'compatible: "pixart,pmw3610-zmk"' "${binding_path}" \
    && ! grep -q '^[[:space:]]*force-high-performance:' "${binding_path}"; then
    cat >>"${binding_path}" <<'EOF'
  force-high-performance:
    type: boolean
EOF
  fi
}

patch_zephyr_sdk_compat() {
  local sdk_cmake_dir="${ZEPHYR_SDK_INSTALL_DIR:-}/cmake"
  local host_tools_path="${WORKSPACE_DIR}/zephyr/cmake/modules/FindHostTools.cmake"
  local generic_path="${WORKSPACE_DIR}/zephyr/cmake/toolchain/zephyr/generic.cmake"
  local target_path="${WORKSPACE_DIR}/zephyr/cmake/toolchain/zephyr/target.cmake"
  local locks_path="${WORKSPACE_DIR}/zephyr/lib/libc/picolibc/locks.c"
  local appcompanion_usb_hid_path="${WORKSPACE_DIR}/zmk-feature-appcompanion/src/layer_status_usb_hid.c"

  [[ -f "${sdk_cmake_dir}/zephyr/gnu/generic.cmake" ]] || return 0
  [[ -f "${sdk_cmake_dir}/zephyr/gnu/target.cmake" ]] || return 0

  if [[ -f "${host_tools_path}" ]] \
    && grep -q 'find_package(Zephyr-sdk 0.16)' "${host_tools_path}"; then
    echo "Applying Zephyr SDK compatibility patch for SDK 1.x..."
    sed -i 's/find_package(Zephyr-sdk 0\.16)/find_package(Zephyr-sdk)/' "${host_tools_path}"
  fi

  if [[ -f "${generic_path}" ]] \
    && grep -q '/cmake/zephyr/generic.cmake' "${generic_path}"; then
    sed -i 's#/cmake/zephyr/generic.cmake#/cmake/zephyr/gnu/generic.cmake#' "${generic_path}"
  fi

  if [[ -f "${target_path}" ]] \
    && grep -q '/cmake/zephyr/target.cmake' "${target_path}"; then
    sed -i 's#/cmake/zephyr/target.cmake#/cmake/zephyr/gnu/target.cmake#' "${target_path}"
  fi

  if [[ -f "${locks_path}" ]] \
    && grep -q '#define _LOCK_T void \*' "${locks_path}"; then
    sed -i 's/#define _LOCK_T void \*/#define _LOCK_T struct __lock */' "${locks_path}"
  fi

  if [[ -f "${locks_path}" ]] \
    && grep -q '^K_MUTEX_DEFINE(__lock___libc_recursive_mutex);' "${locks_path}"; then
    sed -i 's/^K_MUTEX_DEFINE(__lock___libc_recursive_mutex);$/\/\/ K_MUTEX_DEFINE(__lock___libc_recursive_mutex);/' "${locks_path}"
  fi

  if [[ -f "${appcompanion_usb_hid_path}" ]] \
    && grep -q 'static int layer_status_hid_init(const struct device \*dev)' "${appcompanion_usb_hid_path}"; then
    sed -i 's/static int layer_status_hid_init(const struct device \*dev)/static int layer_status_hid_init(void)/' "${appcompanion_usb_hid_path}"
  fi

  if [[ -f "${host_tools_path}" ]] \
    && grep -q 'find_package(Zephyr-sdk)' "${host_tools_path}" \
    && ! grep -q 'find_package(Zephyr-sdk 0.16)' "${host_tools_path}"; then
    SDK_COMPAT_PATCH_ACTIVE=1
  fi
}

reset_zephyr_sdk_compat() {
  local zephyr_repo="${WORKSPACE_DIR}/zephyr"
  local appcompanion_repo="${WORKSPACE_DIR}/zmk-feature-appcompanion"

  [[ "${SDK_COMPAT_PATCH_ACTIVE}" == 1 ]] || return 0
  [[ -d "${zephyr_repo}/.git" ]] || return 0

  git -C "${zephyr_repo}" restore --worktree --source=HEAD -- \
    cmake/modules/FindHostTools.cmake \
    cmake/toolchain/zephyr/generic.cmake \
    cmake/toolchain/zephyr/target.cmake \
    lib/libc/picolibc/locks.c >/dev/null 2>&1 || true

  if [[ -d "${appcompanion_repo}/.git" ]]; then
    git -C "${appcompanion_repo}" restore --worktree --source=HEAD -- \
      src/layer_status_usb_hid.c >/dev/null 2>&1 || true
  fi
}

cleanup_generated_workspace_patches() {
  reset_zephyr_sdk_compat
}

python_has_module() {
  python3 -c "import $1" >/dev/null 2>&1
}

trap cleanup_generated_workspace_patches EXIT

write_firmware_zip() {
  local zip_path="${DIST_DIR}/firmware.zip"

  rm -f -- "${zip_path}"
  (cd "${DIST_DIR}" && zip -q "$(basename "${zip_path}")" "${BUILT_OUTPUTS[@]}")
}

clean_local_outputs() {
  echo "Cleaning local build outputs..."
  rm -rf -- "${WORKSPACE_DIR}/build"
  rm -f -- "${DIST_DIR}"/*.uf2 "${DIST_DIR}/firmware.zip"
  echo "Done."
}

purge_local_workspace() {
  echo "Removing local workspace and dist outputs..."
  rm -rf -- "${WORKSPACE_DIR}" "${DIST_DIR}"
  echo "Done."
}

west_update_needed() {
  (( DO_UPDATE )) && return 0
  [[ ! -d "${WORKSPACE_DIR}/zmk" ]] && return 0
  [[ ! -d "${WORKSPACE_DIR}/zephyr" ]] && return 0
  [[ ! -f "${WEST_UPDATE_MARKER}" ]] && return 0
  [[ "${WEST_MANIFEST_FILE}" -nt "${WEST_UPDATE_MARKER}" ]] && return 0
  return 1
}

run_west_update_if_needed() {
  if west_update_needed; then
    local project_path status dirty=1

    while IFS= read -r project_path; do
      [[ "${project_path}" == "config" ]] && continue
      status="$(git -C "${WORKSPACE_DIR}/${project_path}" status --short --untracked-files=no 2>/dev/null || true)"
      if [[ -n "${status}" ]]; then
        if (( dirty )); then
          echo "Workspace contains local changes that west update may overwrite:" >&2
        fi
        dirty=0
        echo "  ${project_path}:" >&2
        while IFS= read -r line; do
          echo "    ${line}" >&2
        done <<<"${status}"
      fi
    done < <((cd "${WORKSPACE_DIR}" && west list -f '{path}') || true)

    if (( ! dirty )); then
      if (( DO_UPDATE )); then
        echo "Refusing to run west update with a dirty workspace." >&2
        echo "Stash, revert, or purge the local workspace first." >&2
        exit 1
      fi

      echo "Skipping automatic west update because the workspace has local changes." >&2
      touch "${WEST_UPDATE_MARKER}"
      return
    fi

    echo "Updating west workspace..."
    (cd "${WORKSPACE_DIR}" && west update)
    touch "${WEST_UPDATE_MARKER}"
  fi
}

while (($# > 0)); do
  case "$1" in
    --logging)
      ENABLE_LOGGING=1
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --update)
      DO_UPDATE=1
      shift
      ;;
    --pristine)
      PRISTINE="${2:-}"
      if [[ -z "${PRISTINE}" ]]; then
        echo "--pristine requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      REQUESTED_ARTIFACTS+=("$1")
      shift
      ;;
  esac
done

if ((${#REQUESTED_ARTIFACTS[@]} == 1)); then
  case "${REQUESTED_ARTIFACTS[0]}" in
    clean|purge|update)
      ACTION="${REQUESTED_ARTIFACTS[0]}"
      REQUESTED_ARTIFACTS=()
      ;;
  esac
fi

if [[ "${ACTION}" != build ]] && ((${#REQUESTED_ARTIFACTS[@]})); then
  echo "${ACTION} does not accept artifact names" >&2
  exit 1
fi

case "${PRISTINE}" in
  auto|always|never) ;;
  *)
    echo "Invalid pristine mode: ${PRISTINE}" >&2
    exit 1
    ;;
esac

if [[ "${ACTION}" == clean ]]; then
  clean_local_outputs
  exit 0
fi

if [[ "${ACTION}" == purge ]]; then
  purge_local_workspace
  exit 0
fi

require_tool west

if [[ "${ACTION}" == update ]]; then
  sync_config_dir
  if [[ ! -d "${WORKSPACE_DIR}/.west" ]]; then
    (cd "${WORKSPACE_DIR}" && west init -l config)
  fi
  normalize_west_config
  DO_UPDATE=1
  run_west_update_if_needed
  patch_zephyr_sdk_compat
  echo "West workspace updated."
  exit 0
fi

require_tool yq
require_tool python3
require_tool cmake
require_tool ninja

load_build_rows

if (( LIST_ONLY )); then
  list_artifacts
  exit 0
fi

sync_config_dir

mkdir -p "${DIST_DIR}"

if [[ ! -d "${WORKSPACE_DIR}/.west" ]]; then
  (cd "${WORKSPACE_DIR}" && west init -l config)
fi

normalize_west_config

run_west_update_if_needed

patch_zephyr_sdk_compat

if (( ENABLE_LOGGING )) && [[ -d "${WORKSPACE_DIR}/build" ]]; then
  echo "USB logging enabled - cleaning build directories first..."
  rm -rf -- "${WORKSPACE_DIR}/build"
fi

patch_pmw3610_binding

mkdir -p "${WORKSPACE_DIR}/build"

declare -A REQUESTED_SET=()
declare -A FOUND_SET=()
BUILT_OUTPUTS=()
PROTOBUF_OK=""

if ((${#REQUESTED_ARTIFACTS[@]})); then
  for artifact in "${REQUESTED_ARTIFACTS[@]}"; do
    REQUESTED_SET["${artifact}"]=1
  done
fi

for row in "${BUILD_ROWS[@]}"; do
  IFS="${FIELD_SEP}" read -r artifact board shield snippet cmake_args <<<"${row}"

  if ((${#REQUESTED_ARTIFACTS[@]})) && [[ -z "${REQUESTED_SET[${artifact}]+x}" ]]; then
    continue
  fi

  FOUND_SET["${artifact}"]=1

  if [[ "${snippet}" == *studio* ]] || [[ "${cmake_args}" == *CONFIG_ZMK_STUDIO=y* ]]; then
    if [[ -z "${PROTOBUF_OK}" ]]; then
      if python_has_module google.protobuf; then
        PROTOBUF_OK=1
      else
        echo "Artifact ${artifact} requires Python protobuf support for ZMK Studio." >&2
        echo "Install it first (for example: python -m pip install protobuf grpcio-tools)." >&2
        exit 1
      fi
    fi
  fi

  echo "==> Building ${artifact} (${board} / ${shield})"

  cmd=(west build -s zmk/app -b "${board}" -d "build/${artifact}" -p "${PRISTINE}")
  if [[ -n "${snippet}" ]]; then
    cmd+=(-S "${snippet}")
  fi
  if (( ENABLE_LOGGING )); then
    cmd+=(-S zmk-usb-logging)
  fi
  cmd+=(-- "-DSHIELD=${shield}" "-DZMK_CONFIG=${WORKSPACE_CONFIG_DIR}")
  if [[ -n "${cmake_args}" ]]; then
    read -r -a extra_cmake_args <<<"${cmake_args}"
    cmd+=("${extra_cmake_args[@]}")
  fi

  (cd "${WORKSPACE_DIR}" && "${cmd[@]}")

  output_path="${WORKSPACE_DIR}/build/${artifact}/zephyr/zmk.uf2"
  if [[ ! -f "${output_path}" ]]; then
    echo "Expected build output not found: ${output_path}" >&2
    exit 1
  fi

  cp "${output_path}" "${DIST_DIR}/${artifact}.uf2"
  BUILT_OUTPUTS+=("${artifact}.uf2")
done

if ((${#REQUESTED_ARTIFACTS[@]})); then
  for artifact in "${REQUESTED_ARTIFACTS[@]}"; do
    if [[ -z "${FOUND_SET[${artifact}]+x}" ]]; then
      echo "Unknown artifact: ${artifact}" >&2
      echo "Available artifacts:" >&2
      for row in "${BUILD_ROWS[@]}"; do
        printf '  %s\n' "${row%%"${FIELD_SEP}"*}"
      done >&2
      exit 1
    fi
  done
fi

if ((${#REQUESTED_ARTIFACTS[@]} == 0)) && ((${#BUILT_OUTPUTS[@]} > 0)); then
  require_tool zip
  write_firmware_zip
  echo "==> Wrote ${DIST_DIR}/firmware.zip"
fi

echo "==> Finished. Artifacts copied to ${DIST_DIR}:"
printf '  %s\n' "${BUILT_OUTPUTS[@]}"
