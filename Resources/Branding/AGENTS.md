# Branding

- The SVG files are the sources of the app icon and the menu bar symbol, see `README.md`.
- `scripts/render-branding.sh` renders them into `Resources/AppIcon.iconset` and the menu bar PNGs next to the SVGs.
- The PNGs are committed. Render again after every SVG change.
- `ShellStatus.imageName` names the menu bar image of each status.
- `scripts/bundle.sh` copies the PNGs into `Contents/Resources`, and `ShellMenuBarIcon` loads them as template images.
- Outside the bundle, for example with `swift run`, it falls back to the SF Symbol `ShellStatus.symbolName`.
