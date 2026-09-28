# Dashcam app icon

`AppIcon.icon` is the editable Apple Icon Composer document. Its 1024 × 1024 SVG
assets contain only geometry and opaque color. The document supplies the white
background, independent glass surfaces, shadows, translucency and appearance
overrides; these effects are not baked into a single bitmap.

The foreground-to-background order is the recording indicator, window title,
front glass window, and rear glass window. The default appearance has a soft white
base, sage glass and a coral recording dot. Dark and monochrome variants preserve
the same silhouette. System clear and tinted appearances use those annotations.

`scripts/build-icon.sh` uses Xcode 26+ `actool` to produce `Assets.car` (native
layered icon) and `AppIcon.icns` (fallback for older macOS versions). The app's
`CFBundleIconName` and `CFBundleIconFile` both reference `AppIcon`. Run the normal
`npm run build:mac` command to compile and sign the complete app.

Preview images under `docs/assets/icon/` are exported using Apple's renderer:

```sh
"$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool" \
  native/Assets/AppIcon.icon --export-preview macOS Default 1024 1024 1 \
  docs/assets/icon/dashcam-light.png
```

These are original vector assets, rendered by Apple tooling; no generative image
model or raster approximation is used in the shipped icon.
