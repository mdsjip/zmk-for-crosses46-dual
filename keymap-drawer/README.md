## Keymap visualization

- Open `crosses.svg` for the current rendered keymap.
- `crosses.yaml` includes the local `draw_config`.
- `crosses-layout.json` contains the custom physical layout used for local rendering.
- `crosses-web.yaml` is a self-contained approximation for the keymap-drawer web app.

## Regenerate from the ZMK keymap

Preferred from the repo root:

- `bash keymap-drawer/update.sh`

This helper:

- parses `config/crosses.keymap`
- syncs `keymap-drawer/crosses-layout.json` from `config/info.json`
- restores the repo draw config into `crosses.yaml`
- generates `crosses-web.yaml` with tuned `cols_thumbs_notation` for paste-only sharing
- renders `crosses.svg`

Notes:

- Run draw commands from the repo root so the relative path to `keymap-drawer/crosses-layout.json` resolves.
- `update.sh` syncs `crosses-layout.json` from `config/info.json` before re-drawing.
- `crosses-web.yaml` is only an approximation, but preserves the Crosses silhouette better than a plain ortho fallback.

## Install the CLI if needed

- Example: `pipx install keymap-drawer`
