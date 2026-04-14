#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/keymap_drawer.config.yaml"
KEYMAP_FILE="${REPO_ROOT}/config/crosses.keymap"
LAYOUT_SOURCE_FILE="${REPO_ROOT}/config/info.json"
LAYOUT_FILE="${SCRIPT_DIR}/crosses-layout.json"
YAML_FILE="${SCRIPT_DIR}/crosses.yaml"
WEB_YAML_FILE="${SCRIPT_DIR}/crosses-web.yaml"
SVG_FILE="${SCRIPT_DIR}/crosses.svg"

parse_keymap() {
  keymap -c "${CONFIG_FILE}" parse --columns 12 -z "${KEYMAP_FILE}"
}

cp "${LAYOUT_SOURCE_FILE}" "${LAYOUT_FILE}"

# shellcheck disable=SC2016
yq -y -n '
  input as $config
  | input as $keymap
  | $keymap
  | .draw_config = ($config.draw_config // {})
  | .layout = {
      "qmk_info_json": "keymap-drawer/crosses-layout.json",
      "layout_name": (.layout.layout_name // "gggw_crosses_54_layout")
    }
' "${CONFIG_FILE}" <(parse_keymap) >"${YAML_FILE}"

# shellcheck disable=SC2016
yq -y -n '
  input as $config
  | input as $keymap
  | $keymap
  | .draw_config = (($config.draw_config // {}) * {
      "key_w": 56,
      "split_gap": 112
    })
  | .layout = {
      "cols_thumbs_notation": "444^4^4^4+3> 3<+44^4^4^44"
    }
' "${CONFIG_FILE}" <(parse_keymap) >"${WEB_YAML_FILE}"

(cd "${REPO_ROOT}" && keymap draw \
  "keymap-drawer/crosses.yaml" >"${SVG_FILE}")

printf 'Updated:\n- %s\n- %s\n- %s\n- %s\n' "${LAYOUT_FILE}" "${YAML_FILE}" "${WEB_YAML_FILE}" "${SVG_FILE}"
