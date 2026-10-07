import XCTest
@testable import RecorderKit

/// Checks against a real television, sent by the client and the transport the app sends with, and skipped
/// unless `TV_HOST` names one on the LAN:
///
///     TV_HOST=192.0.2.20 swift test --filter LiveTVTests/testWhatIsAtTheAddress
///
/// What is measured of a television with another tool is worth what that tool's way of sending is worth, and
/// no more: a registration sent by a script left the PIN on the screen, and the same one sent by the app did
/// not, because `URLSession` sent it twice (`URLSessionTransportTests`). So what the app relies on is tried
/// from here.
///
/// The first reads what is at the address, needs no registration and changes nothing. Registering takes two
/// runs, since somebody has to read the PIN off the screen in between -- the television on, and showing a
/// broadcast:
///
///     TV_HOST=… TV_JAR=<an absolute path git does not track> swift test --filter LiveTVTests/testRegistering
///     TV_HOST=… TV_JAR=… TV_PIN=<the four digits> swift test --filter LiveTVTests/testRegistering
///
/// The first run puts the PIN on the screen, where it is to stay until it is typed or runs out. The second
/// registers, and keeps the client id and the cookie in the jar; neither is printed. With that jar,
/// `testReadingWhatNeedsTheRegistration` reads the disk and the reservations and says how many there are, not
/// what they are. The television then lists this client under `TV_NICKNAME` (BD Bridge (test) unless set), to
/// be taken off its list by hand afterwards. These three say what they found by its kind -- a television, on
/// or in standby; no answer; an error's code -- and never the television's model or an error as it came,
/// which can have the address in it.
///
/// One more needs no registration and changes nothing: the look a connect makes for a television that did
/// not answer where it was saved, run over the subnet of the address given, with the Mac on the same Wi-Fi
/// and the television in standby for a few minutes, its panel and its lamp watched while it runs:
///
///     TV_HOST=192.0.2.20 swift test --filter LiveTVTests/testFindingTheTelevisionByItsMAC
///
/// It says whether the television was found at the address given, how many addresses were asked and how many
/// seconds that took: never a MAC, and no address but the one given.
///
/// ## The sitting
///
/// The rest are the checks with which the three requests that reserve on a television -- its stations, the
/// question of what a reservation would stop from recording, the create -- meet a real one, sent by the
/// app's own client with the owner at the television. They are `TVSitting`'s, where the rules of a check that
/// writes to somebody's television are written, and `TVSittingTests` rehearses every one of them on the
/// invented television first. They say counts, statuses, error codes, weekdays and times of day, and never a
/// title, a station's name, an id of the television's, an address or a cookie.
///
/// **Every command is written out whole.** Its variables stand on the command line, in front of
/// `swift test`, and are never exported: one left set in the shell goes with every `swift test` after it,
/// the one a commit runs included. Its filter names one test. And every file it names -- `TV_JAR`,
/// `TV_PICKS`, `TV_LEDGER` -- is an absolute path that git does not track: under `notes/` of this
/// repository, or outside it. A test given any other path fails before anything is sent or written. The
/// picks and the ledger say which stations the house receives, and the jar is a key to its television.
///
/// **Before the sitting**, the programmes the checks choose from are picked from the recorder's guide into a
/// file: what a reservation is made of, with no title and no station's name. This sends the television
/// nothing, and the checks send the recorder nothing. With the television on it can be done a minute before
/// the first check. Only a sitting that watches a television in standby has it done before the television is
/// switched off: the recorder is not to be asked anything while that is watched, since what waking a
/// recorder does to a television it is wired to was never measured.
///
///     RECORDER_HOST=… TV_PICKS=<repository>/notes/<a file> \
///         swift test --filter LiveTVTests/testWritingThePicks
///
/// with `TV_PICKS_ALSO=cs:<service id>,bs:<service id>` beside them to name the stations of the last check
/// but one: a CS station, and a station the television lists and does not receive.
///
/// **At the sitting** the television is on and showing a broadcast, its USB disk connected. Before the first
/// check that makes anything the owner looks at the television's own list of reservations, reads two of its
/// settings aloud (remote start; whether a pre-shared key is asked for), and sets one viewing reservation
/// with the remote: for a terrestrial programme that starts on the hour in the evening, a day or more ahead,
/// with nothing else reserved within three hours of it. The checks know that viewing reservation by its
/// start and by nothing else, and the owner says it: `TV_REMINDER`, the day and the minute the programme
/// starts in Japan's time, written as `2026-11-04 21:00`. A check that is about the viewing reservation
/// does not run unless exactly one is listed that starts within a minute of that.
///
/// **Before the first command**, with none of these variables set, the tests are built, in `app/RecorderKit`:
///
///     swift build --build-tests
///
/// so that no command of the sitting spends on building the time it was given.
///
/// Then one check to a command, in the order below, each from `app/RecorderKit`, and **never two commands at
/// once**: one is begun when the one before it has ended.
///
///     TV_HOST=… TV_JAR=… TV_PICKS=… TV_LEDGER=… TV_REMINDER='…' TV_WRITE=<the test> \
///         swift test --filter LiveTVTests/<the test>
///
/// - `TV_LEDGER` is where what is about to be made is written down before it is sent. It is **one file for
///   the whole sitting, the same in every command**, and is not there before the first: each check reads in
///   it what the ones before it left, and the last holds the television's list against it. It keeps when its
///   first entry was written, and a check that would make something, and the last, fail on one begun more
///   than a day before: that file is another sitting's. Two commands at once would each write it over what
///   the other had written in it.
/// - `TV_WRITE` is leave to make something, and is **the name of the test being run**, as in
///   `TV_WRITE=testTheSameProgrammeTwice`. Set to anything else, the test is skipped with nothing sent;
///   without it, or while the television says `standby`, a check that makes something is skipped with
///   nothing made. The two checks for a television in standby, further down, are skipped unless it says just
///   that.
/// - **Every command that carries `TV_WRITE` is given ten minutes** by whatever runs it, and is not
///   interrupted. Cut off between a create and its delete, any of them leaves a reservation on the
///   television and its entry open in the ledger.
/// - **What a check says** is put out line by line as it says it, and each line is added as well to the end
///   of a file beside the ledger: the ledger's path with `.said` on it. Where whatever runs the command
///   shows its output only when the command has ended, that file is where the lines are read while the
///   check runs (`tail -f`).
/// - **No command is started in a minute in which one of the household's own recordings begins or ends**,
///   or would still be running in one. The television's list would not read after the check as it did
///   before it, and the check would fail for what is no fault of the sitting's.
///
/// 1. `testTheStationsAndAPagePastTheEnd`. Makes nothing. To look at, here and in every check below: that
///    the picture goes on as it was.
/// 2. `testAWholeWriteWithTheTelevisionOn`. The eight requests of one reservation, made and deleted. To look
///    at: whether anything shows on the picture as it is made and as it is deleted.
/// 3. `testARecordingWhereAViewingReservationIs`. A recording of the viewing reservation's programme, made
///    and deleted. To look at afterwards: that the viewing reservation is still on the television's list.
/// 4. `testTheSameProgrammeTwice`. The second is to be refused, and one row deleted.
/// 5. `testTheRepeatsOneAtATime`. Six reservations of one programme, one after another, each left on the
///    television for `TV_LOOK` seconds (thirty unless set, and never more than 120). It says the weekday and
///    the time of the programme first, and then each round as it comes, with its code. The six are sent in
///    this order: the programme's own weekday (`w1` for a Monday's to `w5` for a Friday's), by its name
///    (`title`), daily (`d`), Monday to Friday (`w15`), Monday to Saturday (`w16`), and the weekday after
///    the programme's (`w2` to `w6`). To look at, each time, on the television's own list: how the repeat of
///    the reservation at that time is worded, and on which day it stands. A round the television answers
///    with an error makes nothing and has no wait, and the next follows at once: which code is on the
///    television is read from the lines and never counted off. So the lines are followed as they come, in
///    a terminal or from the `.said` file. **It runs for six times `TV_LOOK` and about ten seconds more**:
///    over three minutes as it stands. With `TV_LOOK` above 90 that is too near the ten minutes a command
///    is given, or past them, and it is run in the background. Cut off, it leaves a reservation with a
///    repeat on the television, which records day after day until it is deleted with the remote, and that
///    reservation's entry open in the ledger.
/// 6. `testThreeAtOnce`. Three reservations at one time, twice: the second time beside the viewing
///    reservation. To look at afterwards: the viewing reservation, as it was.
/// 7. `testACreateWithACookieNotTaken`. To look at: that no PIN comes up on the screen.
/// 8. `testTheStationsNamed`. One reservation on each station named with the picks, deleted if it is made.
///    To look at: what the television shows, if anything, for the station it does not receive.
/// 9. `testWhatIsLeftAfterwards`. Makes nothing, and fails unless nothing of the sitting is left. **It has
///    passed only when it says `nothing of the sitting is left`.** A run of it that was skipped -- `TV_WRITE`
///    still naming another test, a file not named -- looked at nothing: a skip is not a pass, and it is run
///    again. It fails as well on a ledger that no check has written in: the wrong file, or a sitting that
///    made nothing. Then the owner deletes the viewing reservation with the remote and looks at the
///    television's own list once more: nothing on it is the sitting's.
///
/// **If the sitting ends early**, after whichever check: `testWhatIsLeftAfterwards` is run all the same,
/// with the same ledger; then the owner deletes the viewing reservation with the remote, which the
/// television would otherwise act on at its time, and looks at the television's own list.
///
/// **After a check that fails**, whatever it says and whether or not it left an entry open in the ledger,
/// the owner looks at the television's own list before the next command. A failure may be what the check was
/// run to find out, and may be something of the sitting left on the television, and what is said does not
/// always tell the one from the other.
///
/// A check that stops on the way says what it left in the ledger, and one that is cut off leaves its entry
/// open without saying so. The next check then **fails**, and makes nothing, until the owner has seen on the
/// television's own list that nothing of the sitting is there, deleting it with the remote if it is, and
/// has set `struck` to `true` on that entry of the ledger by hand. What a check made is listed there under
/// its programme's own name, and not as the BD Bridge 確認 it was sent under: a television gives a
/// reservation a title of its own. It is on the station and at the start its entry gives (the start in UTC).
///
/// ## The sitting at a television in standby
///
/// Two checks are for a television that is switched off and says `standby`: `testAWaitingRowSentInStandby`,
/// described here, and `testAChangeInStandby`, the fourth command below. The first sends one waiting
/// reservation as the app sends what waits for a television with nobody at it: queued in a store of the
/// check's own and sent by the queue's own flush, through the round the app ships. Then it queues and
/// flushes the same reservation a second time, which is to find it on the television and send no create,
/// and takes the row off. It is skipped, with nothing made, unless the television says `standby`.
/// Everything said above of a command holds for both: their variables on the command line, one test to a
/// command, never two at once, their files where git does not track them, the tests built first.
///
/// What it is run to see is the round the app ships -- `PendingQueue.flush` over `ScalarClient` as a
/// `QueueTarget` -- sent to a real television that is off, by the app's own client and transport, and what
/// the panel, the lamp and the disk do meanwhile. How long the television has been off is no part of it. A
/// television was seen to answer alike minutes after it was switched off, when a script made and deleted
/// reservations on it and read its stations, and more than five hours after, when this client read what
/// needs no registration, the disk and the list, and renewed its registration; and the app deleted a
/// reservation on one that was off. So it is one short sitting, at any time of day. Held about a minute
/// after a television was switched off, it passed in seconds, and the owner saw nothing change.
///
/// The programme it reserves is the first among the picks with an empty slot, twenty hours or more ahead,
/// that does not start between midnight and five in the morning in Japan. Run early in the day, twenty
/// hours ahead falls in those hours. A station may be off the air then, the guide lists that as a programme
/// like any other, and what a television answers a create for one has not been seen: the check is not for
/// finding that out.
///
/// **With the television still on**, three things are done first.
///
/// 1. The picks are written (`testWritingThePicks`, above):
///
///        RECORDER_HOST=… TV_PICKS=<repository>/notes/<a file> \
///            swift test --filter LiveTVTests/testWritingThePicks
///
/// 2. The tests are built, with none of these variables set:
///
///        swift build --build-tests
///
/// 3. The registration is in the jar, and the television takes it:
///
///        TV_HOST=… TV_JAR=… swift test --filter LiveTVTests/testReadingWhatNeedsTheRegistration
///
///    Two of the three commands sent once the television is off send with that registration, and
///    registering takes a television that is on and showing a broadcast: a jar found wanting once it is off
///    means switching it on and beginning again.
///
/// **Then whatever else asks the recorder or the television is stopped**, and stays stopped until the check
/// has ended -- a server that refreshes its guide from the recorder, the app on every phone, closed and with
/// its background refresh off -- **and the television is switched off** with its remote, its USB disk
/// connected. Nobody touches it or its remote again until the check has ended, and the recorder is asked
/// nothing after its guide was read for the picks. What waking a recorder does to a television it is wired
/// to was never measured, and what a television does that something else asked meanwhile cannot be put down
/// to the check.
///
/// **Then these commands in this order**, however long the television has been off by then. From the first
/// to the end of the last the owner is at the television and looks at its panel, which is to stay dark; at
/// its lamp; and at the disk, by its own lamp or its sound.
///
/// 1. What is at the address. It is to say a television, in standby. With nothing at the address the
///    sitting ends there: there is nothing to send a reservation to.
///
///        TV_HOST=… swift test --filter LiveTVTests/testWhatIsAtTheAddress
///
/// 2. What needs the registration. The disk is to read as mounted.
///
///        TV_HOST=… TV_JAR=… swift test --filter LiveTVTests/testReadingWhatNeedsTheRegistration
///
/// 3. The check itself:
///
///        TV_HOST=… TV_JAR=… TV_PICKS=… TV_LEDGER=… TV_WRITE=testAWaitingRowSentInStandby \
///            swift test --filter LiveTVTests/testAWaitingRowSentInStandby
///
///    `TV_LEDGER` names a file that is not there yet: this sitting's own, and not the one of a sitting held
///    with the television on. Like every command that carries `TV_WRITE`, it is given ten minutes by
///    whatever runs it and is not interrupted, though it is over in seconds: cut off between its create and
///    its delete, it leaves a reservation on the television and its entry open in the ledger.
///
///    Of each flush it says three things. What the flush sent, a request at a time, by its method and the
///    kind of its answer (`answered`, `error` and a code, `HTTP` and a status, `no answer`): the disk, the
///    list, the stations, the question, the create and the list for the first, and the disk and the list
///    alone for the second. What the queue said of it, by its counts and its stop: `sent 1` for the first,
///    `found there already 1` for the second. And how many rows the list showed it had made: one, and
///    none. A second flush with an `addSchedule` among what it sent fails the check, whatever the queue said
///    of it.
///
///    Its last line is what the television says it is, asked once more as the check ends: `the television
///    says it is: standby`. Whatever is said there fails nothing, and is written down with what was seen of
///    the panel: `active` is not a lit panel. It is not asked after a request that met no answer.
///
/// 4. `testAChangeInStandby`, after the third or in place of it, with the same `TV_LEDGER`:
///
///        TV_HOST=… TV_JAR=… TV_PICKS=… TV_LEDGER=… TV_WRITE=testAChangeInStandby \
///            swift test --filter LiveTVTests/testAChangeInStandby
///
///    It makes one reservation once, changes its repeat to its programme's own weekday by what the app's
///    change sends (the list, `addSchedule` 1.2, the list) and back to once, and deletes it, saying what the
///    television says it is before anything and after every request; it fails, once what it made is taken
///    off, unless that is `standby` throughout, and its last two lines say plainly whether the change was
///    taken in standby and whether the television said `standby` throughout.
///
/// **Then the television is switched on** with its remote, and the count afterwards is run with the same
/// ledger. Its command for this sitting, which has no viewing reservation to name:
///
///     TV_HOST=… TV_JAR=… TV_PICKS=… TV_LEDGER=… TV_WRITE=testWhatIsLeftAfterwards \
///         swift test --filter LiveTVTests/testWhatIsLeftAfterwards
///
/// It has passed only when it says `nothing of the sitting is left`: run with `TV_WRITE` still naming the
/// check, it is skipped, and a skip looked at nothing. The owner looks at the television's own list:
/// nothing on it is the sitting's. Where the check failed or was cut off, the television is switched on and
/// its list looked at before anything else is run, as after any check that fails.
///
/// **How long the television had been off** when the check was run is written down with what was seen of
/// the panel, the lamp and the disk: the check asks for no length of time, and does not say it.
///
/// **When the last sitting is over**, the owner takes the clients that were registered for the checks off
/// the television's list of registered devices -- the one `testRegistering` made, under its nickname, and
/// any registered for a measurement besides -- and the jar is deleted. Before it is,
/// `testReadingWhatNeedsTheRegistration` is run once more, and is to fail with HTTP 403: the television no
/// longer takes the cookie. A registered client is a key to the television from anywhere on the LAN, and is
/// not left there longer than the checks need it.
///
/// ## The sitting that changes a reservation
///
/// Three more checks are for the request that changes a reservation the television holds -- `addSchedule` in
/// the version that takes the list's id, sent with the row as the list gave it and a new repeat -- meeting a
/// real one, sent by the app's own client with the owner at the television (`TVSitting`, after the checks
/// above). The television is on and showing a broadcast, its USB disk connected, and everything said above of
/// a command holds: its variables on the command line and never exported, one test to a command and never two
/// at once, every command that carries `TV_WRITE` given ten minutes and not interrupted, its files where git
/// does not track them, the owner looking at the television's own list after a check that fails. A change
/// writes nothing in the ledger: it makes nothing, and a row a check made keeps the entry its create wrote.
///
/// **Before the sitting**:
///
/// 1. A registration of its own, the clients registered for the checks having been taken off: with the
///    television on and showing a broadcast, `testRegistering` twice, as above, with a `TV_JAR` that is not
///    there yet and then with `TV_PIN` beside it.
/// 2. The picks, minutes before the first check: `testWritingThePicks`, as above.
/// 3. The tests built, with none of these variables set: `swift build --build-tests`.
/// 4. The owner looks at the television's own list, and then sets with the remote one recording reservation,
///    once, of a terrestrial programme a day or more ahead that starts between four in the morning and
///    midnight, at a time of day nothing else on the list stands at on any day; and, where the television's
///    own menu can make a reservation by its date and time, one such, made the same way. The owner says the
///    start of each, as `TV_REMINDER` is written. These are the last reservations made on the television
///    before the checks.
///
/// **Then these, in this order**, each from `app/RecorderKit`, with one `TV_LEDGER` for all of them that is not
/// there before the first:
///
/// 1. `testAChangeInPlace`:
///
///        TV_HOST=… TV_JAR=… TV_PICKS=… TV_LEDGER=… TV_LOOK=<seconds> TV_WRITE=testAChangeInPlace \
///            swift test --filter LiveTVTests/testAChangeInPlace
///
///    It makes one reservation, once, of a weekday's programme that starts from four in the morning, at a
///    time nothing is listed at on any day, and changes it one request at a time, saying of each what it
///    was answered and what the list then reads: to the programme's own weekday, the same again, by its
///    name, daily, Monday to Friday, Monday to Saturday, the next weekday, which is to be refused with
///    error 7 and leave the row as it was, and back to once. Daily is left on the television for `TV_LOOK`
///    seconds: to look at, on the television's own list, that it records every day. Then the row is deleted,
///    and the change is sent once more for it, which is to be refused with error 41200 and make nothing.
///    It leaves nothing. Where its first change is refused, it sends the same with the title the create was
///    sent with and with none, takes the row off and fails: what the app sends is decided from those.
/// 2. `testAChangeOfARowMadeWithTheRemote`, once for each reservation the owner made, `TV_REMOTE` its start
///    and, where there are two, `TV_REMOTE_ALSO` the other's:
///
///        TV_HOST=… TV_JAR=… TV_PICKS=… TV_LEDGER=… TV_REMOTE='…' TV_REMOTE_ALSO='…' TV_LOOK=<seconds> \
///            TV_WRITE=testAChangeOfARowMadeWithTheRemote \
///            swift test --filter LiveTVTests/testAChangeOfARowMadeWithTheRemote
///
///    It changes nothing unless exactly one recording starts within a minute of `TV_REMOTE`, the newest in
///    the list by the number in its id (where two are named, the two newest are the two named), recording
///    once, with nothing else in the list at its time of day on any day. It says whether the row has a
///    programme id and its repeat, changes it to its own weekday's code (daily, for one that starts before
///    four in the morning), leaves it so for `TV_LOOK` seconds while the owner looks at the television's own
///    list, and changes it back. It never deletes it, and fails unless it reads as it began, saying which
///    repeat it reads with: the owner then sets it back with the remote.
/// 3. `testARepeatOnADayWithTwoAtItsTime`:
///
///        TV_HOST=… TV_JAR=… TV_PICKS=… TV_LEDGER=… TV_WRITE=testARepeatOnADayWithTwoAtItsTime \
///            swift test --filter LiveTVTests/testARepeatOnADayWithTwoAtItsTime
///
///    It makes three reservations, once: two of programmes that start together on two stations, A and B, and
///    one of a programme on a third station at that time of day the day before, C. It says which of them the
///    television names when asked what C would stop from recording every day, changes C to daily only where
///    every row named is its own, says how A, B and C then read, changes C back to once and deletes all
///    three. What it is run to see is whether a repeat a change adds can cost a recording on a later day, and
///    whether the list and the question say so.
/// 4. `testWhatIsLeftAfterwards`, with the same ledger, as above: it has passed only when it says `nothing of
///    the sitting is left`. Then the owner deletes with the remote the reservations made for the sitting and
///    looks at the television's own list once more.
///
/// **Afterwards** the owner takes the client registered for the sitting off the television's list of
/// registered devices; `testReadingWhatNeedsTheRegistration` is then to fail with HTTP 403, and the jar is
/// deleted.
final class LiveTVTests: XCTestCase {
    func testWhatIsAtTheAddress() async throws {
        let client = try liveClient(MemoryTVCredentials())
        let presence = await client.presence()
        print("at the address: \(TVSitting.said(ofWhatAnswers: presence))")
        switch presence {
        case .nothing, .notATelevision: XCTFail("no television is at the address")
        case .standby, .on: break
        }
        await byItsKind("the MAC to wake it by") {
            print("gives a MAC to wake it by: \(try await client.wakeOnLANAddress(timeout: 5) != nil)")
        }
    }

    func testRegistering() async throws {
        let jar = try liveJar()
        let client = try liveClient(jar)
        let clientID = jar.load()?.clientID ?? "BDBridge:\(UUID().uuidString)"
        // Kept before anything is sent: the PIN goes with the client id that asked for it.
        if jar.load() == nil { jar.save(TVCredentials(clientID: clientID)) }
        let pin = ProcessInfo.processInfo.environment["TV_PIN"].flatMap { $0.isEmpty ? nil : $0 }
        let nickname = ProcessInfo.processInfo.environment["TV_NICKNAME"] ?? "BD Bridge (test)"

        // The two requests the app's `enrol` sends, in its order, and not `enrol` itself: what that hands
        // back for a failure is a sentence for the app's screen, which can have the address in it.
        await byItsKind("registering") {
            _ = try await client.wakeOnLANAddress(timeout: 5)
            switch try await client.register(clientID: clientID, nickname: nickname, pin: pin) {
            case .pinNeeded:
                print("the television asked for its PIN: it is on the screen now, and is to stay there")
                XCTAssertNil(pin, "the PIN given was not taken")
            case .registered:
                print("registered: the cookie is in the jar")
                XCTAssertNotNil(jar.load()?.cookie)
            }
        }
    }

    func testReadingWhatNeedsTheRegistration() async throws {
        let jar = try liveJar()
        guard jar.load()?.cookie != nil else { throw XCTSkip("Nothing is registered in the jar yet.") }
        let client = try liveClient(jar)
        await byItsKind("reading what needs the registration") {
            let storage = try await client.storage()
            print("disk to record to: mounted \(storage.mounted)")
            let rows = try await client.schedules()
            print("schedules: \(rows.count), of which recordings \(rows.filter { $0.type == "recording" }.count)")
        }
    }

    /// The look a connect makes for a television that did not answer where it was saved (`TVDiscovery.find`,
    /// which the app's link is given): the MAC read at the address given, as an attach reads it, and then that
    /// MAC looked for over the subnet the address is on, through the session the app sends a television with,
    /// which keeps no cookie and follows no redirect. Every address is sent the one request that needs no
    /// registration. It is found where it is: the pass is that it is found at the address given, and that the
    /// panel and the lamp stay as they were.
    func testFindingTheTelevisionByItsMAC() async throws {
        let client = try liveClient(MemoryTVCredentials())
        var given: String?
        await byItsKind("the MAC to find it by") { given = try await client.wakeOnLANAddress(timeout: 5) }
        let mac = try XCTUnwrap(given, "the television gives no MAC to find it by")
        let hosts = LocalNetwork.hostsToScan(near: client.host)
        guard !hosts.isEmpty else { return XCTFail("this Mac is on no Wi-Fi whose subnet the address is on") }
        let counted = AddressesAsked(URLSessionTransport.withoutCookies())

        let started = Date()
        let found = await TVDiscovery.find(mac: mac, among: hosts, transport: counted)
        let seconds = Date().timeIntervalSince(started)
        let asked = await counted.count

        print("found at the address given: \(found == client.host ? "yes" : "no")")
        print("addresses asked: \(asked) of \(hosts.count)")
        print("seconds: \(String(format: "%.1f", seconds))")
        // Not said by value: a failure would print another address.
        XCTAssertTrue(found == client.host, "not found at the address given")
    }

    /// Sends what `requests` sends, and fails the test by the kind of what went wrong (`TVSitting.said`),
    /// never with the error as it came: a television's error can carry the address it was sent to, and
    /// XCTest prints whatever a test throws.
    private func byItsKind(_ what: String, _ requests: () async throws -> Void) async {
        do { try await requests() } catch { XCTFail("\(what): \(TVSitting.said(error))") }
    }

    // MARK: - the sitting

    /// Reads the recorder's guide and sends the television nothing: every terrestrial programme still to
    /// start, and those of the stations named, by what a reservation of each is made of.
    func testWritingThePicks() async throws {
        guard let host = Self.environment("RECORDER_HOST") else {
            throw XCTSkip("Set RECORDER_HOST to the recorder whose guide the picks are taken from.")
        }
        guard let file = try Self.file("TV_PICKS") else {
            throw XCTSkip("Set TV_PICKS to a file to write the picks to, outside what the repository tracks.")
        }
        let named = try (Self.environment("TV_PICKS_ALSO") ?? "").split(separator: ",").map { text in
            try XCTUnwrap(TVPicks.Channel(String(text)), "TV_PICKS_ALSO is <kind>:<service id>, comma separated")
        }

        // What goes wrong with the recorder is thrown by its kind: as it comes, it has the address in it.
        let picks = try await TVPicks.picked(from: RecorderClient(host: host), named: named, after: Date())
        try picks.write(to: file)

        print("picks: \(picks.programmes.count) programmes on \(Set(picks.programmes.map(\.channel)).count) channels")
        for (index, channel) in named.enumerated() {
            let programmes = picks.programmes.filter { $0.channel == channel }.count
            print("station \(index + 1) of those named: \(programmes) programmes")
            XCTAssertGreaterThan(programmes, 0, "station \(index + 1) of those named is not in the recorder's guide")
        }
        XCTAssertFalse(picks.programmes.isEmpty, "the guide gave no programme to pick")
    }

    func testTheStationsAndAPagePastTheEnd() async throws {
        try await sitting { try await $0.theStations() }
    }

    func testAWholeWriteWithTheTelevisionOn() async throws {
        try await sitting { try await $0.aWholeWrite() }
    }

    func testARecordingWhereAViewingReservationIs() async throws {
        try await sitting { try await $0.aRecordingWhereAViewingReservationIs() }
    }

    func testTheSameProgrammeTwice() async throws {
        try await sitting { try await $0.theSameProgrammeTwice() }
    }

    func testTheRepeatsOneAtATime() async throws {
        try await sitting { try await $0.theRepeats() }
    }

    /// One repeat at a time, for an owner who reads the television's own list at their own pace: `TV_REPEAT`
    /// names it (`weekly`, `title`, `daily`, `weekdays`, `weekdaysAndSaturday`), and the reservation stays on
    /// the television until a file is put beside the ledger -- the ledger's path with `.looked` on it
    /// (`touch`) -- or eight minutes have passed, whichever comes first, and is then deleted. It is run in the
    /// background, since it ends when somebody says so; what it says is read from the `.said` file meanwhile.
    func testOneRepeatLeftUntilLookedAt() async throws {
        guard let which = Self.environment("TV_REPEAT") else {
            throw XCTSkip("Set TV_REPEAT to the repeat to try: one of \(TVSitting.repeatsByName).")
        }
        guard let ledger = try Self.file("TV_LEDGER") else { throw XCTSkip("Set TV_LEDGER.") }
        let looked = ledger.appendingPathExtension("looked")
        try? FileManager.default.removeItem(at: looked)
        try await sitting { sitting in
            try await sitting.oneRepeat(which) {
                // Never without an end: left to itself the reservation would record day after day.
                let end = Date().addingTimeInterval(8 * 60)
                while !FileManager.default.fileExists(atPath: looked.path), Date() < end {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                try? FileManager.default.removeItem(at: looked)
            }
        }
    }

    func testThreeAtOnce() async throws {
        try await sitting { try await $0.threeAtOnce() }
    }

    func testACreateWithACookieNotTaken() async throws {
        // The registered client id with a cookie the television never gave, in a store of its own: nothing
        // of it reaches the jar, and no cookie this client is answered with would be kept.
        guard let clientID = try liveJar().load()?.clientID else {
            throw XCTSkip("Nothing is registered in the jar yet.")
        }
        let never = TVCredentials(clientID: clientID, cookie: String(repeating: "0", count: 40))
        let stranger = try liveClient(MemoryTVCredentials(never))
        try await sitting { try await $0.aCreateWithACookieNotTaken(sentBy: stranger) }
    }

    func testTheStationsNamed() async throws {
        try await sitting { try await $0.theStationsNamed() }
    }

    /// A waiting row sent to a television in standby (`TVSitting.aWaitingRowInStandby`): on one that says it is
    /// on, it is skipped with nothing made.
    func testAWaitingRowSentInStandby() async throws {
        try await sitting { try await $0.aWaitingRowInStandby() }
    }

    func testWhatIsLeftAfterwards() async throws {
        try await sitting { try await $0.whatIsLeft() }
    }

    // MARK: - the sitting that changes a reservation

    func testAChangeInPlace() async throws {
        try await sitting { try await $0.aChangeInPlace() }
    }

    /// The reservation the owner made with the remote, named by its start (`TV_REMOTE`), and where the owner
    /// made two, the other's start beside it (`TV_REMOTE_ALSO`): the check tells the two from the rest of the
    /// list by their starts and their ids, and changes the one at `TV_REMOTE`.
    func testAChangeOfARowMadeWithTheRemote() async throws {
        let named = try Self.start("TV_REMOTE"), other = try Self.start("TV_REMOTE_ALSO")
        try await sitting { try await $0.aChangeOfARowMadeWithTheRemote(startingAt: named, alsoNamed: other) }
    }

    func testARepeatOnADayWithTwoAtItsTime() async throws {
        try await sitting { try await $0.aRepeatOnADayWithTwoAtItsTime() }
    }

    /// The change of a reservation's repeat to a television in standby (`TVSitting.aChangeInStandby`): on one
    /// that says it is on, it is skipped with nothing made.
    func testAChangeInStandby() async throws {
        try await sitting { try await $0.aChangeInStandby() }
    }

    /// The start a variable names, in Japan's time, written as `TV_REMINDER` is (`TVSitting.reminderStart`),
    /// or nil when it is not set.
    private static func start(_ name: String) throws -> Date? {
        try environment(name).map { text in
            try XCTUnwrap(TVSitting.reminderStart(text), "\(name) is a start in Japan's time, as 2026-11-04 21:00")
        }
    }

    /// Runs one check of the sitting against the television at `TV_HOST`, with the registration in `TV_JAR`,
    /// the picks in `TV_PICKS`, the ledger in `TV_LEDGER` and the viewing reservation that starts at
    /// `TV_REMINDER`. There is leave to write only when `TV_WRITE` is the name of the test that called, which
    /// `#function` gives here; and when it is the name of another, this one is skipped with nothing sent, so
    /// that a command runs the one check it names whatever its filter lets through.
    ///
    /// A check that refuses to run -- no leave, the television in standby for a check that wants it on or
    /// on for one that wants it in standby, no slot that is empty, no viewing reservation named -- is
    /// skipped with its reason: it made nothing. Whatever else a check throws fails the test, an entry left
    /// open in the ledger included: something of the sitting may be on the television. What a check says is
    /// put out line by line as it is said, and kept in a file beside the ledger for whatever runs the
    /// command and cannot see it meanwhile (`TVSitting.printer`).
    private func sitting(_ test: String = #function, _ check: (TVSitting) async throws -> Void) async throws {
        let leave = Self.environment("TV_WRITE")
        let mayWrite = TVSitting.mayWrite(leave, running: test)
        guard leave == nil || mayWrite else {
            throw XCTSkip("TV_WRITE is not the name of this test: a command of the sitting runs the one it names.")
        }
        let jar = try liveJar()
        let (client, line) = try live(jar)
        guard jar.load()?.cookie != nil else { throw XCTSkip("Nothing is registered in the jar yet.") }
        guard let ledger = try Self.file("TV_LEDGER") else {
            throw XCTSkip("Set TV_LEDGER to a file for the sitting's ledger, outside what the repository tracks.")
        }
        guard let picks = try Self.file("TV_PICKS") else {
            throw XCTSkip("Set TV_PICKS to the file testWritingThePicks wrote.")
        }
        let reminder = try Self.environment("TV_REMINDER").map { text in
            try XCTUnwrap(TVSitting.reminderStart(text),
                          "TV_REMINDER is the start of the viewing reservation in Japan's time, as 2026-11-04 21:00")
        }
        let sitting = TVSitting(client: client, line: line, picks: try TVPicks.read(picks, namedBy: "TV_PICKS"),
                                ledger: ledger, mayWrite: mayWrite, reminder: reminder,
                                look: Self.environment("TV_LOOK").flatMap { TimeInterval($0) } ?? 30,
                                say: TVSitting.printer(beside: ledger))
        do {
            try await check(sitting)
        } catch let refused as TVSitting.Refused {
            throw XCTSkip(refused.why)
        }
    }

    private static func environment(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The file a variable names, or nil when it is not set. A path that is not absolute, or that lies in
    /// the working tree where git would pick the file up, is refused before anything is read, written or
    /// sent (`TVSitting.mayKeep`): the test fails, saying which variable and nothing of the path.
    private static func file(_ name: String) throws -> URL? {
        guard let path = environment(name) else { return nil }
        guard TVSitting.mayKeep(at: path) else {
            throw TVSitting.Stopped(what: "\(name) has to be an absolute path that git does not track: under notes/"
                                    + " of this repository, or outside it")
        }
        return URL(fileURLWithPath: path)
    }

    private func liveClient(_ credentials: any TVCredentialStore) throws -> ScalarClient {
        try live(credentials).client
    }

    /// The client every test here sends with, and the line it is built on: the transport the app sends
    /// with, under a line that keeps the method of each request and the kind of its answer (`TVLine`). A
    /// check of the sitting is handed both, and the one for a television in standby says from the line what
    /// the round sent. The line changes nothing of what is sent or of what comes back.
    private func live(_ credentials: any TVCredentialStore) throws -> (client: ScalarClient, line: TVLine) {
        guard let host = ProcessInfo.processInfo.environment["TV_HOST"], !host.isEmpty else {
            throw XCTSkip("Set TV_HOST to a television's address to run this.")
        }
        let line = TVLine(URLSessionTransport.withoutCookies())
        return (ScalarClient(host: host, transport: line, credentials: credentials), line)
    }

    private func liveJar() throws -> FileTVCredentials {
        guard let file = try Self.file("TV_JAR") else {
            throw XCTSkip("Set TV_JAR to a file to keep the registration in, outside what the repository tracks.")
        }
        return FileTVCredentials(file)
    }
}

/// Counts the addresses a look sent anything to, and keeps nothing else of them.
private actor AddressesAsked: HTTPTransport {
    private let transport: any HTTPTransport
    private var asked: Set<String> = []

    init(_ transport: any HTTPTransport) { self.transport = transport }

    var count: Int { asked.count }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        asked.insert(request.url.host() ?? "")
        return try await transport.send(request)
    }
}

/// A registration kept in a file between two runs, readable by its owner alone. For the checks above only:
/// the app keeps its own in the Keychain.
private final class FileTVCredentials: TVCredentialStore, @unchecked Sendable {
    private let file: URL

    init(_ file: URL) { self.file = file }

    func load() -> TVCredentials? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(TVCredentials.self, from: $0) }
    }

    func save(_ credentials: TVCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func remove() { try? FileManager.default.removeItem(at: file) }
}
