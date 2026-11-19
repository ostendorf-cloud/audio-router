// Copyright 2026 Simon Ostendorf
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import RouterCore

struct FormattingTests {
    @Test func devicesShowUidNameAndChannels() {
        let text = Formatting.devices([
            OutputDevice(objectID: 1, uid: "b-uid", name: "Speakers", channelCount: 2),
            Samples.device,
        ])
        #expect(
            text == """
                UID        NAME      CHANNELS
                mixer-uid  Mixer     32
                b-uid      Speakers  2
                """)
    }

    @Test func emptyListsSayWhatIsMissing() {
        #expect(Formatting.devices([]) == "No output devices.")
        #expect(Formatting.apps([]) == "No audio processes with a bundle id.")
    }

    @Test func appsAreGroupedUnderTheParent() {
        let text = Formatting.apps([
            Samples.process(1, "com.google.Chrome", pid: 10, playing: false),
            Samples.process(2, "com.google.Chrome.helper", pid: 20),
        ])
        #expect(
            text == """
                com.google.Chrome  (2 processes, 1 playing)
                  com.google.Chrome  pid 11  idle
                  com.google.Chrome.helper  pid 22  playing
                """)
    }
}
