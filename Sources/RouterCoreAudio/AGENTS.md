# RouterCoreAudio

- It needs a Mac, devices and the capture permission. It holds `routerIOProc` and all audio thread code.
- `ChannelMapper` is split. Its pure parts stay in `RouterCore`.
  `render`, `markActive` and `measure` read `AudioBufferList`.
  So they are an extension in `ChannelMapperRealTime.swift`, next to `MeterBlock`.
- Symbols both libraries need are `package`, not `public`.
  `package` keeps them out of the public API. Every target of this package still sees them.
- The tap uses `mutedWhenTapped`, so a stopped IO proc lets the app play again.
  Do not switch to `muted` without a new decision in the concept.
- The target device is a sub device of the aggregate.
- `ChannelMapper.chooseTapBuffers` finds the tap among the device inputs and refuses when that is ambiguous.
  Keep that check.
- The stream id diff (`createAggregate`, then `ChannelMapper.tapBufferByStreamDiff`) names the tap buffer when it can.
  When it fails and the device inputs have the tap shape, the layout cannot prove the order.
  The route then needs `--tap-buffer`. Do not widen the rule.
- `Tests/RouterCoreAudioTests` runs the real time code on in memory buffer lists.
- API names come from the SDK headers, not from memory, see the root file.
