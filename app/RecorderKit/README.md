# RecorderKit

The recorder-facing layer of the iOS app, as a Swift package with no UI and no networking. That keeps it
testable from the command line on the Mac:

```
cd app/RecorderKit
swift test
```

The tests read the conformance vectors in [`docs/port/`](../../docs/port), which are generated from the Python
server that talks to the real recorder. Whatever they cover is guaranteed to behave the same way in both
implementations. See [`docs/porting.md`](../../docs/porting.md) for the plan and for the recorder's quirks.

## What is here

| File | Contents |
|---|---|
| `Xml.swift` | A small XML tree over `XMLParser`. Namespaces are dropped and only local names are kept |
| `Codes.swift` | Broadcasting, quality, repeat and genre tables; the UPnP ports, service names and control URLs |
| `Text.swift` | ARIB additional symbols spelled out, private-use characters removed |
| `Soap.swift` | XML escaping, the SOAP envelope and headers, hex helpers |
| `RecorderTime.swift` | JST formatting and parsing. The recorder rejects `+0900` and wants `+09:00` |
| `XsrsElements.swift` | The reservation and title payloads, byte-identical to what the official app sends |
| `XsrsParse.swift` | `<item>` elements into `Reservation` and `RecordedTitle` |
| `Discovery.swift` | `description.xml` into `RecorderDescription`, and looking through a subnet for one |
| `LocalNetwork.swift` | This device's own interfaces, the addresses worth trying around them, and where a broadcast goes |
| `WakeOnLan.swift` | The magic packet, and where to aim it for a recorder that has left the network |
| `Models.swift` | `Reservation`, `RecordedTitle`, `RecorderDescription` |
| `Http.swift` | Request and response types and the transport protocol, so the tests can stub the network |
| `SerialQueue.swift` | One request at a time, in the order the calls arrive |
| `RecorderError.swift` | Faults, transport failures, and what the UPnP error codes mean |
| `RecorderClient.swift` | One recorder: identity, reservations, recordings, playback, free space, guide files |
| `Inflate.swift` | One zlib stream at a time, reporting how much input it used |
| `Epg.swift` | The guide file: XOR, the zlib run, and the @SRV / @DAY / @EVT records |
| `Guide.swift` | `GuideService`, `GuideProgram` and `Genre` |
| `Sqlite.swift` | A thin wrapper over the system SQLite, so the package needs no dependencies |
| `GuideStore.swift` | The guide cache: channels, programmes, logos, the user's channel order |
| `Logo.swift` | The station-logo file, and the broadcast colour table the PNGs rely on |
| `Series.swift` | Programme names and grouping keys from recording titles |
| `Titles.swift` | Watch states, and recordings gathered into programmes |
| `BulkWork.swift` | What to do about one recording in a run of many, including the recorder's two traps |
| `Duplicates.swift` | Copies of one broadcast, and which copy to keep |

Every file in `docs/port/` is checked from here: `codes.json`, `xsrs.json`, `description.json`,
`epg-sample`, `logo-sample`, `series.json` and `titles.json`.

A read-only check against a real recorder is included and skipped by default:

```
RECORDER_HOST=<recorder ip> swift test --filter LiveRecorderTests
```

It only reads, so it cannot change what the recorder is going to record. Compare its printed figures with the
same ones from the Python server to see that both agree.

## What is not here

The app itself is in `app/BDBridge`, beside this package and depending on it. Everything with a screen
lives there; everything that talks to a recorder or decodes one of its files lives here.

Keyword auto-reservation is still only on the server side, which is the right place for it: it has to run
whether or not anybody is holding a phone.
