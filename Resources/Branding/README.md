# Branding

The app icon and the menu bar symbol of audio-router. Drawn by hand as SVG, licensed Apache-2.0 like the repository.
No stock art and no fonts: every shape is a path.

## Motif

- One wave on the left splits into a channel pair on the right.
  That is a route: one app to one channel pair.
- The same three paths make the menu bar symbol and the app icon.

## Files

- `app-icon.svg`: the app icon source.
- `menubar-off.svg`, `menubar-running.svg`, `menubar-warning.svg`, `menubar-error.svg`: one menu bar symbol per
  `ShellStatus`.
- `menubar-<state>.png` and `menubar-<state>@2x.png`: rendered template images, 16 and 32 pixels.
- `preview.png`: contact sheet of both on a light and a dark background, for review.
- `../AppIcon.iconset`: the rendered app icon, 16 to 512 pt at 1x and 2x, so 16 to 1024 pixels.

## Menu bar symbol

- Template image: black on transparent. macOS uses the alpha only and paints it in the menu bar colour.
- Grid: 16 x 16 pt. Stroke 1.5 pt, round caps and joins.
  The channel pair lies on y 4.25 and 10.75, so its edges fall on whole pixels at 2x.
- Running: the plain symbol.
- Off: a slash from the upper left to the lower right.
- Warning: a triangle with an exclamation mark at the lower right.
- Error: a disc with an exclamation mark at the lower right.
- A clip path with an even odd hole cuts a gap around the slash and the marks.
  Masks are not used: CoreSVG rasterises a mask at the 16 pt size, and its edge blurs at 2x.
- At 1x the triangle and the disc are small blobs. They read clearly at 2x.

## App icon

- 1024 x 1024 canvas, body 824 x 824 at 100, a rounded square with continuous corners.
- Gradient from `#1b4db3` at the upper left to `#0a7f7c` at the lower right.
- The motif in white, stroke 1.6 on the 16 grid, scaled by 40 around the centre.
- No drop shadow.

## Rendering

```sh
scripts/render-branding.sh
```

- It compiles `scripts/render-branding.swift` with `swiftc` and renders every SVG with AppKit.
  `NSImage` reads SVG through CoreSVG, so it needs only macOS and the Command Line Tools.
- It writes the menu bar PNGs, the iconset and `preview.png`. Two runs give identical files.
- Run it after every SVG change and commit the PNGs. `scripts/bundle.sh` uses the committed files.
