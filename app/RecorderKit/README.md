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
| `Discovery.swift` | `description.xml` into `RecorderDescription`, rejecting anything that is not a recorder |
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

Every file in `docs/port/` is checked from here: `codes.json`, `xsrs.json`, `description.json`,
`epg-sample`, `logo-sample`, `series.json` and `titles.json`.

A read-only check against a real recorder is included and skipped by default:

```
RECORDER_HOST=192.0.2.63 swift test --filter LiveRecorderTests
```

It only reads, so it cannot change what the recorder is going to record. Compare its printed figures with the
same ones from the Python server to see that both agree.

## What is next

The app target, which is not in this repository yet; when it arrives it will live beside this package in `app/`
and depend on it as a local package.

Still on the server side only: finding a recorder by scanning the subnet, duplicate detection among
recordings, keyword auto-reservation, and Wake-on-LAN. None of them is needed to put a guide and a
reservation list on screen.
