# Changelog

## v0.1.0 (2026-11-25)

### Features

- **app:** add a logo, app icon and menu bar symbol ([#66](https://github.com/ostendorf-cloud/audio-router/pull/66))
- **app:** add live route meters ([#55](https://github.com/ostendorf-cloud/audio-router/pull/55))
- **app:** show route issues with messages and actions ([#54](https://github.com/ostendorf-cloud/audio-router/pull/54))
- **app:** add a start at login toggle to Settings ([#52](https://github.com/ostendorf-cloud/audio-router/pull/52))
- **app:** add the route editor with pair pickers ([#53](https://github.com/ostendorf-cloud/audio-router/pull/53))
- **app:** add the menu bar item, menu and settings window ([#48](https://github.com/ostendorf-cloud/audio-router/pull/48))
- **core:** add the route engine with device and app recovery ([#41](https://github.com/ostendorf-cloud/audio-router/pull/41))
- **core:** add the device model and a debounced device monitor ([#39](https://github.com/ostendorf-cloud/audio-router/pull/39))
- **core:** add a process monitor for routed apps ([#37](https://github.com/ostendorf-cloud/audio-router/pull/37))
- **core:** add the route model and a versioned JSON store ([#36](https://github.com/ostendorf-cloud/audio-router/pull/36))
- warn on a tap that does not match the source pair ([#12](https://github.com/ostendorf-cloud/audio-router/pull/12))
- find the tap stream by stream id diff, default to device stream ([#10](https://github.com/ostendorf-cloud/audio-router/pull/10))
- add route --meter and the prototype follow-ups ([#7](https://github.com/ostendorf-cloud/audio-router/pull/7))
- add the phase 1 command line prototype ([#3](https://github.com/ostendorf-cloud/audio-router/pull/3))

### Bug Fixes

- **app:** show no warning when an app plays nothing ([#64](https://github.com/ostendorf-cloud/audio-router/pull/64))
- **app:** build with the Command Line Tools without SwiftUI macros ([#59](https://github.com/ostendorf-cloud/audio-router/pull/59))
- **core:** stop a route at once when its device is lost or no longer the default ([#50](https://github.com/ostendorf-cloud/audio-router/pull/50))
- add the device-stream tap mode against the 24 dB mixdown loss ([#9](https://github.com/ostendorf-cloud/audio-router/pull/9))
