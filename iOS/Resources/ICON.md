# The iPhone app's icon

The iPhone app has Sorello's icon, the Mac app's picture drawn to the edges: the mark, a row of dots rising into the
aurora dot, on the near-black field, which fills the square because iOS cuts an icon's corners itself
([ARCHITECTURE.md](../../ARCHITECTURE.md), section 8, "The mark"). `AppIcon-Source.png` is the App Store build's.
`AppIcon-Dev-Source.png` is the development build's, with a few orange stars on the field, so the two builds can be
told apart on one iPhone.

The icon is drawn in code, not edited here: `AppIconGeometry` in `DesignCore` lays it out and `AppIconView` in
`SorelloUI` draws it. To write both files again, from the repository's root on a Mac:

```sh
swift run SorelloSnapshots --ios-icon iOS/Resources/AppIcon-Source.png
swift run SorelloSnapshots --ios-dev-icon iOS/Resources/AppIcon-Dev-Source.png
```

`make snapshots` shows them as an iPhone does, in the `mark-iphone-icon` pictures. The Makefile flattens the build's
file and compiles it into the app's asset catalog.
