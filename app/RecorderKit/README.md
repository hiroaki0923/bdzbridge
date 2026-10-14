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
| `DeviceSearch.swift` | One search for the recorder and the television together, every address of the Wi-Fi asked whether it is either, and what each address turned out to be |
| `ScanTally.swift` | A search's requests passed on and counted by how each came back, which tells a subnet with nobody on it from a phone that let nothing out |
| `TVDiscovery.swift` | Looking through the subnet for a television, by the loop a look for a recorder goes through, with nothing registered in what is sent |
| `LocalNetwork.swift` | This device's own interfaces, the addresses worth trying around them, and where a broadcast goes |
| `LocalNetworkAccess.swift` | Whether iOS's local network permission is what is stopping a request |
| `ScanLog.swift` | What a search, and the links' wait for and look at the local network permission, leave in the system's log |
| `RecorderAddress.swift` | The recorder's address as somebody types it, tidied, and the URLs the client builds on it |
| `WakeOnLan.swift` | The magic packet, and where to aim it for a recorder that has left the network |
| `Models.swift` | `Reservation`, `RecordedTitle`, `RecorderDescription`, `Recognition`, `RecorderRule`, `NetworkSettings` |
| `Http.swift` | Request and response types and the transport protocol, so the tests can stub the network |
| `SerialQueue.swift` | One request at a time, in the order the calls arrive; and a turn that is waited for and given back, for work that has to stay in the task that asked for it |
| `RecorderError.swift` | Faults, transport failures, and what the UPnP error codes mean |
| `DeviceFailure.swift` | What a failure means whichever device it came from: silent, busy, refused and the rest |
| `DeviceEndpoint.swift` | What the shared rules ask of a device: to be probed, sent a waiting reservation in its own way, asked for a guide; and the recorder's way of sending one, which reads its list first and leaves a row it holds already unsent |
| `RecorderClient.swift` | One recorder: identity, reservations, recordings, playback, free space, guide files |
| `Waking.swift` | Waiting for a recorder to come back after a magic packet |
| `Reach.swift` | The order of one attempt at a device: packet, probe, permission, waking, looking elsewhere |
| `LinkRules.swift` | Whether to give up, try once more or make sure of the device first; where it was last tried |
| `SessionState.swift` | What the app knows of a device and its link to it, changed only by what happened |
| `DeviceLink.swift` | The connection to one device: connecting, the check before an operation, silence and giving up, coming back to the app, the network changing, whether to wait for the local network permission; the client whose attach heard which device answers, what a check heard in its place, and how often the device was let go of. A check is joined only while it is out |
| `LinkOperation.swift` | What something asked of a device through its link is made of, whichever device: the line on the screen while it is out, how it failed and the sentence for it (`OperationFailure`), what is said and done about that, and the whole in order for an operation of one request (`run`) |
| `ReservationDriver.swift` | The six steps of a device's reservations both drivers answer alike -- the list, the pull-down, a delete, a change, a reservation, a waiting row sent again -- with one request value for a change and a reservation (`ReservationTerms`); the app's hosts ask both drivers through it |
| `RecorderDriver.swift` | What is particular to a recorder in a link: who answered and whose the cache is, what every attach reads, waking it, finding it at another address; and its reservations -- read, made, changed and deleted, what waits for it sent, sent again and deleted -- by the rules a television's keep, each answered with its sentence |
| `RecorderRecordings.swift` | The recorder's recordings, by the same rules: the list with the free space, read once for everyone who asks together, a recording's details, protect and delete (and which recordings cannot be deleted), playback, turning a recorder in standby on to play and waiting for it, and the power; how one of these is asked of the recorder |
| `RecorderConditions.swift` | The recorder's own keyword conditions, by the same rules: read with why they could not be, added (to the USB disk after the slot answers) and deleted, each under its one line, with the list read after an add that went through or a delete the recorder answered |
| `RecorderRuns.swift` | The recorder's side of a run over many recordings -- the bulk delete, the bulk protect and the scan for duplicates -- by the same rules: its words, when a run may begin and go on, one recording asked a request at a time with the recorder's two traps, why a run stopped, and the free space read as it ends |
| `RecorderGuide.swift` | The guide fetched by hand and at a connect, by the same rules: the step, the press that connects first where the recorder cannot be asked, the asking that makes sure of the recorder once a refresh has its turn and before each later file, and what a refresh came to, for its screen to say |
| `RecorderNoScreen.swift` | The recorder's runs with no screen, which have no link: the one attempt at the recorder, whether the one that answered is the one the cache is of, the order of the overnight run and of the Shortcuts action's sending, what each tells and what it tells once, and the sentences |
| `ScalarClient.swift` | A Sony BRAVIA's own control API: the JSON-RPC envelope, its errors, the registration by PIN and the cookie it hands out |
| `TVDriver.swift` | What is particular to a television in a link: asked whether it is on and never woken, told apart by the MAC it wakes on, renewed while registered; and its reservations -- read, made, changed and deleted, what waits for it sent, sent again and deleted |
| `TVSchedule.swift` | One row of a television's schedule list as read, kept in the television's own spellings, and the rule that finds it again before a change or a delete |
| `TVReservation.swift` | A station as a television lists it, and what the two reservation requests send for one reservation on it |
| `TVNoScreen.swift` | The television's runs with no screen, which have no link: the one attempt at the television, what a sending came to, for either device, and what is said of it; and the rule of what is told once and kept between runs (`TVTold.after`), with a device's own words for it (`NoScreenWords`), which the recorder's runs tell by as well |
| `DemoTV.swift` | An invented BRAVIA that answers in the real one's shapes, for the tests and the demo |
| `DemoRecorder.swift` | An invented BDZ-FBT4100 that answers in the real one's XML and remembers what is done to it, for the demo and the tests |
| `DemoLineUp.swift` | The invented stations and their days the demo's guide, recorder and television are made of |
| `Activities.swift` | What is under way with the device, each piece of work with a line of its own |
| `Inflate.swift` | One zlib stream at a time, reporting how much input it used |
| `Epg.swift` | The guide file: XOR, the zlib run, and the @SRV / @DAY / @EVT records |
| `Guide.swift` | `GuideService`, `GuideProgram` and `Genre` |
| `Sqlite.swift` | A thin wrapper over the system SQLite, so the package needs no dependencies |
| `GuideStore.swift` | The guide cache: channels, programmes, logos, the user's channel order |
| `GuideRefresh.swift` | Fetching the guide and its logos a broadcasting type at a time, one refresh at a time in the process and only into the cache of the recorder it was fetched from; which types are behind, and when the overnight run is asked for |
| `PendingQueue.swift` | Sending the reservations that were made while their device could not be reached, a row at a time by the device's own way of sending one and only as the round read the row, and the sentences for what became of them |
| `ByProgram.swift` | Whether a device's list holds a reservation that answers for a waiting row: the same programme, a repeat that is all the row asks for, and not one the recorder made for itself |
| `Logo.swift` | The station-logo file, and the broadcast colour table the PNGs rely on |
| `Series.swift` | Programme names and grouping keys from recording titles |
| `Titles.swift` | Watch states, and recordings gathered into programmes |
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
