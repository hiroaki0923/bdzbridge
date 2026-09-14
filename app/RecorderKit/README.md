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

Covered by vectors so far: `codes.json`, `xsrs.json`, `description.json`. The EPG and logo decoders and the
programme-grouping heuristic are not ported yet, so `epg-sample`, `logo-sample` and `series.json` are still
unused here.

A read-only check against a real recorder is included and skipped by default:

```
RECORDER_HOST=192.168.0.63 swift test --filter LiveRecorderTests
```

It only reads, so it cannot change what the recorder is going to record. Compare its printed figures with the
same ones from the Python server to see that both agree.

## What is next

The EPG decoder: XOR 0x9D, the concatenated zlib streams and the "@SRV/@DAY/@EVT" container, checked against
`epg-sample`. Then the guide cache on the device. The app target itself is not in this repository yet; when it
arrives it will live beside this package in `app/` and depend on it as a local package.
