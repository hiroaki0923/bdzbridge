# RecorderKit

The recorder-facing layer of the iOS app, as a Swift package with no UI. Its tests hand it the recorder's
answers through a stubbed transport, so they run from the command line on the Mac with no recorder to ask:

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
| `LocalNetworkAccess.swift` | Whether iOS's local network permission is what is stopping a request |
| `RecorderAddress.swift` | The recorder's address as somebody types it, tidied, and the URLs the client builds on it |
| `WakeOnLan.swift` | The magic packet, and where to aim it for a recorder that has left the network |
| `Models.swift` | `Reservation`, `RecordedTitle`, `RecorderDescription`, `Recognition`, `RecorderRule`, `NetworkSettings` |
| `Http.swift` | Request and response types and the transport protocol, so the tests can stub the network |
| `SerialQueue.swift` | One request at a time, in the order the calls arrive |
| `RecorderError.swift` | Faults, transport failures, and what the UPnP error codes mean |
| `DeviceFailure.swift` | What a failure means whichever device it came from: silent, busy, refused and the rest |
| `DeviceEndpoint.swift` | What the shared rules ask of a device: to be probed, sent a waiting reservation in its own way, asked for a guide; and the recorder's way of sending one, which reads its list first and leaves a row it holds already unsent |
| `RecorderClient.swift` | One recorder: identity, reservations, recordings, playback, free space, guide files |
| `Waking.swift` | Waiting for a recorder to come back after a magic packet |
| `Reach.swift` | The order of one attempt at a device: packet, probe, permission, waking, looking elsewhere |
| `LinkRules.swift` | Whether to give up, try once more or make sure of the device first; where it was last tried |
| `SessionState.swift` | What the app knows of a device and its link to it, changed only by what happened |
| `DeviceLink.swift` | The connection to one device: connecting, the check before an operation, silence and giving up, coming back to the app, the network changing, whether to wait for the local network permission; the client whose attach heard which device answers, what a check heard in its place, and how often the device was let go of |
| `LinkOperation.swift` | What something asked of a device through its link is made of, whichever device: the line on the screen while it is out, how it failed and the sentence for it (`OperationFailure`), what is said and done about that, and the whole in order for an operation of one request (`run`) |
| `RecorderDriver.swift` | What is particular to a recorder in a link: who answered and whose the cache is, what every attach reads, waking it, finding it at another address; and its reservations -- read, made, changed and deleted, what waits for it sent, sent again and deleted -- by the rules a television's keep, each answered with its sentence |
| `ScalarClient.swift` | A Sony BRAVIA's own control API: the JSON-RPC envelope, its errors, the registration by PIN and the cookie it hands out |
| `TVDriver.swift` | What is particular to a television in a link: asked whether it is on and never woken, told apart by the MAC it wakes on, renewed while registered; and its reservations -- read, made, changed and deleted, what waits for it sent, sent again and deleted |
| `DemoTV.swift` | An invented BRAVIA that answers in the real one's shapes, for the tests and the demo |
| `Activities.swift` | What is under way with the device, each piece of work with a line of its own |
| `Inflate.swift` | One zlib stream at a time, reporting how much input it used |
| `Epg.swift` | The guide file: XOR, the zlib run, and the @SRV / @DAY / @EVT records |
| `Guide.swift` | `GuideService`, `GuideProgram` and `Genre` |
| `Sqlite.swift` | A thin wrapper over the system SQLite, so the package needs no dependencies |
| `GuideStore.swift` | The guide cache: channels, programmes, logos, the user's channel order |
| `GuideRefresh.swift` | Fetching the guide and its logos a broadcasting type at a time, and which types are behind |
| `PendingQueue.swift` | Sending the reservations that were made while their device could not be reached, a row at a time by the device's own way of sending one, and the sentences for what became of them |
| `ByProgram.swift` | Whether a device's list holds a reservation that answers for a waiting row: the same programme, a repeat that is all the row asks for, and not one the recorder made for itself |
| `Logo.swift` | The station-logo file, and the broadcast colour table the PNGs rely on |
| `Series.swift` | Programme names and grouping keys from recording titles |
| `Titles.swift` | Watch states, and recordings gathered into programmes |
| `BulkWork.swift` | What to do about one recording in a run of many, including the recorder's two traps |
| `Duplicates.swift` | Copies of one broadcast, and which copy to keep |

Every file in `docs/port/` is checked from here: `codes.json`, `xsrs.json`, `description.json`,
`epg-sample`, `logo-sample`, `series.json` and `titles.json`.

A check against a real recorder is included and skipped by default:

```
RECORDER_HOST=<recorder ip> swift test --filter LiveRecorderTests
```

So run, it only reads, and cannot change what the recorder is going to record. Compare its printed figures with
the same ones from the Python server to see that both agree. With `RECORDER_WRITE=1` set as well, the tests that
say so write: they make a reservation or a keyword condition and delete it again. The one that makes, changes
and deletes a reservation through the recorder's driver, as the app does
(`testTheDriverMakesChangesAndDeletesAReservation`), runs only with `RECORDER_MAC` set too, and is rehearsed
on an invented recorder by `DriverCheckRehearsalTests`. It takes for its own only the one new row at the
programme's channel and start: where more than one could be, it writes nothing more, deletes none of them, and
says that a reservation may be left at that time. A recorder that has left the network answers
nothing; with `RECORDER_MAC=<the recorder's MAC>` set as well, each test first wakes it as the app does and
waits up to a minute for it to answer, printing how long that took. The MAC is never printed.

## What is not here

The app itself is in `app/BDBridge`, beside this package and depending on it. Everything with a screen
lives there; everything that talks to a recorder or decodes one of its files lives here.

Keyword auto-reservation is still only on the server side, which is the right place for it: it has to run
whether or not anybody is holding a phone.
