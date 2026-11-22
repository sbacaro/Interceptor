import InterceptorEngine
import Testing

@Suite("Core Audio Device Catalog Smoke Tests")
struct CoreAudioCatalogSmokeTests {
    @Test("Enumerates host macOS output interfaces without crashing and reports valid streams")
    func enumeratesHostOutputDevices() {
        let catalog = CoreAudioDeviceCatalog()
        let devices = catalog.fetchOutputDevices()

        // Any macOS host with built-in audio or virtual bridges should report at least one output device.
        #expect(!devices.isEmpty)
        for device in devices {
            #expect(!device.uid.isEmpty)
            #expect(device.totalOutputChannels > 0)
            #expect(!device.outputStreams.isEmpty)
            #expect(!device.uid.hasPrefix(CoreAudioDeviceCatalog.privateAggregateUIDPrefix))
        }
    }

    @Test("Filters out system daemons and helper processes, returning only commercial applications")
    func filtersOutSystemDaemonsFromProcessList() {
        let catalog = CoreAudioDeviceCatalog()
        let apps = catalog.fetchAudioProcesses()

        let forbiddenDaemonNames: Set<String> = [
            "audiomxd",
            "assistantd",
            "avconferenced",
            "cloudpaird",
            "heard",
            "mediaremoted",
            "systemsoundserverd",
            "universalaccessd",
            "voicebankingd",
            "CoreSpeech",
            "PowerChime",
            "Siri",
            "Clock",
            "Find My",
            "Home",
            "Journal",
            "Stocks",
            "Weather",
            "helper"
        ]

        for app in apps {
            #expect(!forbiddenDaemonNames.contains(app.displayName))
            #expect(!(app.bundleID ?? "").isEmpty)
        }
    }
}
