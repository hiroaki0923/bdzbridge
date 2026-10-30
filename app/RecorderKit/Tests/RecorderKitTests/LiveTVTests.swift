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
/// And the look of the app's search for both kinds, over the same subnet, the television and the recorder in
/// standby and both fronts watched while it runs:
///
///     TV_HOST=192.0.2.20 swift test --filter LiveTVTests/testLookingRoundTheSubnetForBoth
///
/// It says how many recorders and televisions answered, whether the television at the address given was among
/// them with its model, and the seconds the look took: never a model, and no address but the one given.
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

    /// The look of the app's one search, レコーダーとテレビを探す (`DeviceSearch.scan`), over the subnet of the
    /// address given, through the session the app sends a search with, which keeps no cookie and follows no
    /// redirect: every address is asked for a recorder's description and a television's interface at once,
    /// neither of which needs a registration or changes anything. It says how many of each kind answered,
    /// whether the television at the address given was among them and gave its model, and how many seconds the
    /// look took -- never a model, nor an address but the one given. The pass is that the television is found
    /// where it is, and that its panel and lamp, and the recorder's front, stay as they were.
    func testLookingRoundTheSubnetForBoth() async throws {
        let client = try liveClient(MemoryTVCredentials())
        let hosts = LocalNetwork.hostsToScan(near: client.host)
        guard !hosts.isEmpty else { return XCTFail("this Mac is on no Wi-Fi whose subnet the address is on") }

        let started = Date()
        let found = await DeviceSearch.scan(hosts: hosts, transport: URLSessionTransport.withoutCookies())
        let seconds = Date().timeIntervalSince(started)
        let television = found.televisions.first { $0.host == client.host }

        print("addresses asked: \(hosts.count)")
        print("recorders: \(found.recorders.count); televisions: \(found.televisions.count)")
        print("the television at the address given among them: \(television == nil ? "no" : "yes")")
        print("its model given: \(television.map { $0.model.isEmpty ? "no" : "yes" } ?? "no")")
        print("seconds: \(String(format: "%.1f", seconds))")
        XCTAssertNotNil(television, "the television at the address given was not found")
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

// MARK: - the recordings on the television's disk

/// The television's recordings -- `avContent.getContentList` and `getContentCount` of `usb:recStorage` -- read
/// through the client's own entry for them (`ScalarClient.contentPage`, `contentCount`) on the transport the app
/// sends with, and, with leave, protected, unprotected and deleted by the client's requests for those. What every
/// one of them says is counts, error codes, key names, the types of values, the form a start and a uri are
/// written in, power states and seconds; of a recording, its place in the list, its start as a time of day
/// (HH:mm, Japan time), its length in minutes and its short flags; never a title, a channel's name or number, a
/// uri or an address. Each request is said as it is sent, and what came of it once it came.
///
/// Every command is written out whole, from `app/RecorderKit`, its variables on the command line in front of
/// `swift test` and never exported, one test to a command and never two at once; `TV_JAR` is the registration
/// `testRegistering` kept, which `testReadingWhatNeedsTheRegistration` is run with first to see the television
/// still takes it. The disk the television records to is connected, with at least one recording on it that the
/// owner made with the remote; two let `testTheRecordingsPagePastTheEnd` check where a page starts directly.
///
/// The versions a list is asked for in are named by the labels of `ContentAsking.lists`: `1.0`, `1.2`, `1.2+all`
/// and `1.5`. `testReadingTheRecordings` asks in all of them; the others ask in the one `TV_CONTENT_VERSION`
/// names, the one that read best there.
extension LiveTVTests {
    /// The recordings read with the television on, in every version: `getPowerStatus`, `getStorageList`,
    /// `getContentCount` 1.0, 1.1 and 1.1 with `target` `all`, `getContentList` 1.0, 1.2, 1.2 with `target` `all`
    /// and 1.5 (by `uri`), each a page of fifty from the first row, and `getRecordingStatus`, with the power status
    /// read after each request. Makes nothing.
    ///
    ///     TV_HOST=192.0.2.20 TV_JAR=<the jar> swift test --filter LiveTVTests/testReadingTheRecordings
    ///
    /// The television is on, the owner at it watching the panel, which is to go on as it was. For each version it
    /// says how many rows came or the error's code, or, for an answer that is no page, its structure by types
    /// alone; the keys of the rows, with how many rows have each and the types its values came as, nested ones
    /// too; how the start is written and whether the app reads it; the forms of the uris and the names of their
    /// query's parameters; the values of the flags (`isProtected`, `isNew`, `hasResume` and the like); then each
    /// row by its place, start, length and protection, whether it has `recordingInfo` and `stateInfo`, and its
    /// short values, nested ones too, which is how a recording being recorded is told from one that has ended;
    /// and whether the counts match the rows. A write below names a recording by the start said here.
    func testReadingTheRecordings() async throws {
        let client = try recordingsClient()
        let say = Self.sayAtOnce
        await Self.sayingPower(of: client, say, "at first")
        await ask("getStorageList", of: client, say) { "mounted \(try await client.storage().mounted)" }
        var counts: [String: Int] = [:]
        for asking in ContentAsking.counts {
            await ask(asking.said, of: client, say) {
                let count = try await client.contentCount(version: asking.version, params: asking.params(0, 0))
                counts[asking.label] = count
                return "\(count)"
            }
        }
        var listed: [String: Int] = [:]
        for asking in ContentAsking.lists {
            await ask(asking.said, of: client, say) {
                let rows = try await Self.page(asking, 0, 50, of: client, say)
                listed[asking.label] = rows.count
                for line in RecordingRows.shape(of: rows) { say("  " + line) }
                for line in RecordingRows.each(rows) { say("  " + line) }
                return "\(rows.count) rows"
            }
        }
        await ask("getRecordingStatus", of: client, say) { try await client.recordingStatus() }
        for (count, number) in counts.sorted(by: { $0.key < $1.key }) {
            let matching = listed.filter { $0.value == number }.keys.sorted()
            say("count \(count) (\(number)) matches the rows of: \(matching.isEmpty ? "none" : matching.joined(separator: ", "))")
        }
    }

    /// The recordings asked for in every other way the television's signatures offer: `getContentCount` 1.1 by
    /// `type` and `target`, and `getContentList` 1.5 by `view`, `target`, `type` and `filter`. Makes nothing; run
    /// when the television's own list shows more recordings than `testReadingTheRecordings` read. It says the
    /// disk's capacity and free space, to hold against the sizes of the rows, and for each way how many rows came
    /// or the error's code, with the rows themselves where they are not the plain list's.
    ///
    ///     TV_HOST=192.0.2.20 TV_JAR=<the jar> swift test --filter LiveTVTests/testOtherWaysOfAskingForTheRecordings
    func testOtherWaysOfAskingForTheRecordings() async throws {
        let client = try recordingsClient()
        let say = Self.sayAtOnce
        await Self.sayingPower(of: client, say, "at first")
        await ask("getStorageList", of: client, say, afterwards: false) {
            let disk = try await client.storage()
            return "mounted \(disk.mounted), free \(disk.freeMB ?? -1) MB of \(disk.totalMB ?? -1) MB"
        }
        let source = ScalarClient.recordingsSource
        for type in [nil, "", "video", "recording", "recorded", "tv", "movie"] as [String?] {
            for target in [nil, "", "all", "video", "recording", "recorded", "new"] as [String?] {
                var params: [String: ScalarValue] = ["source": .string(source)]
                if let type { params["type"] = .string(type) }
                if let target { params["target"] = .string(target) }
                await ask("count, type \(type ?? "-"), target \(target ?? "-")", of: client, say, afterwards: false) {
                    "\(try await client.contentCount(version: "1.1", params: params))"
                }
            }
        }
        let plain = try await client.contentPage(version: "1.5", params: ["uri": .string(source), "stIdx": 0, "cnt": 50])
        say("the plain list: \(plain.count) rows")
        for line in RecordingRows.each(plain) { say("  " + line) }
        let ways: [(String, [String: ScalarValue])] =
            ["flat", "tree", "all", "folder", "group"].map { ("view \($0)", ["view": .string($0)]) }
            + ["all", "video", "recording", "recorded", "new"].map { ("target \($0)", ["target": .string($0)]) }
            + ["video", "recording", "recorded", "tv", "movie"].map { ("type \($0)", ["type": .list([.string($0)])]) }
            + ["all", "new", "recorded", "recording", "protected"].map { ("filter \($0)", ["filter": .list([.string($0)])]) }
            + [("view flat, target all", ["view": "flat", "target": "all"])]
        for (label, extra) in ways {
            var params: [String: ScalarValue] = ["uri": .string(source), "stIdx": 0, "cnt": 50]
            params.merge(extra) { _, new in new }
            await ask("list, \(label)", of: client, say, afterwards: false) {
                let rows = try await client.contentPage(version: "1.5", params: params)
                if rows != plain { for line in RecordingRows.each(rows) { say("  " + line) } }
                return "\(rows.count) rows\(rows == plain ? ", as the plain list" : "")"
            }
        }
        await Self.sayingPower(of: client, say, "at the end")
    }

    /// The pages of a list in the version `TV_CONTENT_VERSION` names, at and past its end: the list read fifty
    /// rows at a time until a short page, then a page from the row one past the last, from the number of rows,
    /// from one more and from fifty more, pages of a hundred and of two hundred from the first, and one row from
    /// the second, held against the second row of the first page to say where `stIdx` counts from. Makes nothing.
    ///
    ///     TV_HOST=192.0.2.20 TV_JAR=<the jar> TV_CONTENT_VERSION=<1.0, 1.2, 1.2+all or 1.5> \
    ///         swift test --filter LiveTVTests/testTheRecordingsPagePastTheEnd
    ///
    /// The television is on, the owner at it watching the panel. It says, for each page, how many rows came or the
    /// error's code, and the `index` the first rows give, if they give one; and where `stIdx` counts from, by the
    /// second row where there are two, otherwise by the page from the number of rows.
    func testTheRecordingsPagePastTheEnd() async throws {
        let client = try recordingsClient()
        let asking = try ContentAsking.named()
        let say = Self.sayAtOnce
        await Self.sayingPower(of: client, say, "at first")
        var all: [[String: ScalarValue]] = []
        await ask("the list fifty at a time", of: client, say, afterwards: false) {
            all = try await Self.everyRow(asking, of: client)
            return "\(all.count) rows"
        }
        let indexes = all.prefix(3).map { $0["index"].map(RecordingRows.said) ?? "-" }
        say("their index fields, the first three: \(indexes.joined(separator: ", "))")
        let pages: [(String, Int, Int)] = [("from the number of rows", all.count, 50),
                                           ("from one more", all.count + 1, 50),
                                           ("from fifty more", all.count + 50, 50),
                                           ("a hundred from the first", 0, 100),
                                           ("two hundred from the first", 0, 200)]
        var pastTheLast: Int?
        for (what, index, count) in pages {
            await ask("\(what) (stIdx \(index), cnt \(count))", of: client, say, afterwards: false) {
                let rows = try await Self.page(asking, index, count, of: client, say)
                if index == all.count, count == 50 { pastTheLast = rows.count }
                return "\(rows.count) rows"
            }
        }
        if all.count >= 2 {
            await ask("one row from the second (stIdx 1, cnt 1)", of: client, say, afterwards: false) {
                let rows = try await Self.page(asking, 1, 1, of: client, say)
                let same = rows.first?["uri"] != nil && rows.first?["uri"] == all[1]["uri"]
                return "\(rows.count) rows, the second row of the list: \(same ? "yes, stIdx counts from 0" : "no")"
            }
        } else if !all.isEmpty, let pastTheLast {
            say("stIdx, by the page from the number of rows: " + (pastTheLast == 0
                ? "counts from 0 (the page past the last row is empty)"
                : "counts from 1, or a page past the end is not empty (\(pastTheLast) rows)"))
        }
        await Self.sayingPower(of: client, say, "at the end")
    }

    /// The recordings read with the television in standby, in the version `TV_CONTENT_VERSION` names:
    /// `getPowerStatus`, `getStorageList`, `getContentCount` 1.1, a page of fifty, `getRecordingStatus`, the power
    /// status after each, fifteen seconds between one request and the next, and half a minute for the disk to
    /// answer a count or a page. Makes nothing, and refuses unless the television says `standby` at first.
    ///
    ///     TV_HOST=192.0.2.20 TV_JAR=<the jar> TV_CONTENT_VERSION=<1.0, 1.2, 1.2+all or 1.5> \
    ///         swift test --filter LiveTVTests/testTheRecordingsInStandby
    ///
    /// The television has been switched off with its remote a few minutes before, and nothing else asks it or the
    /// recorder anything meanwhile. The owner is at it, watching the panel, which is to stay dark, the lamp, and
    /// the disk, by its lamp or its sound, and writes down what each did after which request: each is said as it
    /// is sent. It says what `testReadingTheRecordings` says of the version, and the power state before and after:
    /// `active` is not a lit panel.
    func testTheRecordingsInStandby() async throws {
        let client = try recordingsClient()
        let asking = try ContentAsking.named()
        let say = Self.sayAtOnce
        let power: String
        do {
            power = try await client.powerStatus()
        } catch {
            return XCTFail("getPowerStatus: \(TVSitting.said(error))")
        }
        say("power at first: \(power)")
        guard power == "standby" else { throw XCTSkip("the television says \(power), not standby") }
        let gap = Duration.seconds(15), disk: TimeInterval = 30
        await ask("getStorageList", of: client, say) { "mounted \(try await client.storage().mounted)" }
        try await Task.sleep(for: gap)
        if let count = ContentAsking.counts.first(where: { $0.label == "1.1" }) {
            await ask(count.said, of: client, say) {
                "\(try await client.contentCount(version: count.version, params: count.params(0, 0), timeout: disk))"
            }
            try await Task.sleep(for: gap)
        }
        await ask(asking.said, of: client, say) {
            let rows = try await Self.page(asking, 0, 50, of: client, say, timeout: disk)
            for line in RecordingRows.shape(of: rows) { say("  " + line) }
            for line in RecordingRows.each(rows) { say("  " + line) }
            return "\(rows.count) rows"
        }
        try await Task.sleep(for: gap)
        await ask("getRecordingStatus", of: client, say) { try await client.recordingStatus() }
        await Self.sayingPower(of: client, say, "at the end")
    }

    // MARK: - writes, at one sitting with the owner at the television

    /// **Writes to the television.** Protects a recording and lifts the protection, by the client's request for
    /// it (`ScalarClient.setDeleteProtection`), reading the list before and after each.
    ///
    ///     TV_HOST=192.0.2.20 TV_JAR=<the jar> TV_CONTENT_VERSION=<the version> TV_TARGET_START=<HH:mm> \
    ///         TV_WRITE=testProtectingARecordingAndLiftingIt \
    ///         swift test --filter LiveTVTests/testProtectingARecordingAndLiftingIt
    ///
    /// `TV_TARGET_START` is the start of the recording to write to, as `testReadingTheRecordings` listed it: one
    /// the owner made with the remote for the sitting, to be thrown away. The television is on and recording
    /// nothing, the owner at it watching the panel and, after each step, the protection the television's own list
    /// of recordings shows. It refuses, sending nothing, unless `TV_WRITE` is this test's name, the television says
    /// `active` and `notStarted`, and exactly one recording starts at that time of day, has ended and is not
    /// protected; a row that gives no length the app reads is taken as ended, since the television says it is
    /// recording nothing. After each write the list is read every two seconds, for twenty at most, until it shows
    /// the change, and the seconds that took are said, with the power status. A protection that may be left on
    /// when the test ends, however it ends, is said, to be lifted with the remote.
    func testProtectingARecordingAndLiftingIt() async throws {
        try await recordingWrite { at in
            let target = try await at.target(protected: false)
            try await at.protect(target, true)
            let lifted = try await at.protect(target, false)
            XCTAssertEqual(lifted, false, "the recording is not read as unprotected at the end: lift it with the remote")
        }
    }

    /// **Writes to the television.** Protects a recording, sends its delete while it is protected, and lifts the
    /// protection: what the television answers a delete of a protected recording, and whether the recording is
    /// still there. The delete is sent only once the list reads the recording as protected.
    ///
    ///     TV_HOST=192.0.2.20 TV_JAR=<the jar> TV_CONTENT_VERSION=<the version> TV_TARGET_START=<HH:mm> \
    ///         TV_WRITE=testDeletingAProtectedRecording \
    ///         swift test --filter LiveTVTests/testDeletingAProtectedRecording
    ///
    /// The same state, the same refusals and the same reading after each write as
    /// `testProtectingARecordingAndLiftingIt`, on the same throwaway recording. The owner watches the panel, and
    /// afterwards that the recording is on the television's own list and not protected. If it was deleted all the
    /// same, that is the finding, and it is said; and then, once no list in any version has it, the same delete is
    /// sent again, for what the television answers a delete of a uri it no longer has, which
    /// `testDeletingARecordingTwice` can no longer be run for.
    func testDeletingAProtectedRecording() async throws {
        try await recordingWrite { at in
            let target = try await at.target(protected: false)
            guard try await at.protect(target, true) == true else {
                at.say("not read as protected: no delete is sent")
                return XCTFail("the protection was not seen in the list")
            }
            if try await at.delete(target, "the delete while protected") != nil {
                try await at.protect(target, false)
            } else {
                at.say("the recording was deleted though it was protected")
                try await at.deleteAgain(target)
            }
        }
    }

    /// **Writes to the television.** Deletes a recording, by the client's request for it
    /// (`ScalarClient.deleteContent`), and, once the list no longer has it, sends the same delete again: what the
    /// television answers a delete of a uri it no longer has. The second is sent only when no row of the list in
    /// any of the versions carries that uri, so that it cannot reach another recording.
    ///
    ///     TV_HOST=192.0.2.20 TV_JAR=<the jar> TV_CONTENT_VERSION=<the version> TV_TARGET_START=<HH:mm> \
    ///         TV_WRITE=testDeletingARecordingTwice \
    ///         swift test --filter LiveTVTests/testDeletingARecordingTwice
    ///
    /// The same state, the same refusals and the same reading after each write as
    /// `testProtectingARecordingAndLiftingIt`, on the same throwaway recording, which is deleted: run it last. The
    /// owner watches the panel, and afterwards that the recording is gone from the television's own list and
    /// nothing else is. It says how many rows the list lost besides.
    func testDeletingARecordingTwice() async throws {
        try await recordingWrite { at in
            let target = try await at.target(protected: false)
            guard try await at.delete(target, "the delete") == nil else {
                at.say("still listed: the delete is not sent again")
                return XCTFail("the recording is still listed after its delete")
            }
            try await at.deleteAgain(target)
        }
    }

    /// Runs one of the writes above on the television at `TV_HOST`, with the registration in `TV_JAR`, reading the
    /// list in the version `TV_CONTENT_VERSION` names and writing to the recording that starts at
    /// `TV_TARGET_START`, after the television has said `active` and `notStarted`. Skipped with nothing sent unless
    /// `TV_WRITE` is the name of the test that called (`TVSitting.mayWrite`). However the steps end, a protection
    /// they may have left on is said.
    private func recordingWrite(_ test: String = #function, _ steps: (RecordingWrite) async throws -> Void)
        async throws {
        guard TVSitting.mayWrite(Self.environment("TV_WRITE"), running: test) else {
            throw XCTSkip("Set TV_WRITE to the name of this test to let it write to the television.")
        }
        let client = try recordingsClient()
        let asking = try ContentAsking.named()
        guard let start = Self.environment("TV_TARGET_START") else {
            throw XCTSkip("Set TV_TARGET_START to the start (HH:mm) of the recording, as testReadingTheRecordings listed it.")
        }
        let say = Self.sayAtOnce
        let power = try await Self.sayingItsKind("getPowerStatus") { try await client.powerStatus() }
        let recording = try await Self.sayingItsKind("getRecordingStatus") { try await client.recordingStatus() }
        say("before anything: power \(power), recording \(recording)")
        guard power == "active" else { throw XCTSkip("the television says \(power), not active") }
        guard recording == "notStarted" else { throw XCTSkip("the television says it is recording (\(recording))") }
        let at = RecordingWrite(client: client, asking: asking, start: start, say: say)
        do {
            try await steps(at)
        } catch {
            at.sayIfLeftProtected()
            throw error
        }
        at.sayIfLeftProtected()
        await Self.sayingPower(of: client, say, "at the end")
    }

    /// The client for the recordings, with the registration in the jar; skipped with nothing sent without one.
    private func recordingsClient() throws -> ScalarClient {
        let jar = try liveJar()
        guard jar.load()?.cookie != nil else { throw XCTSkip("Nothing is registered in the jar yet.") }
        return try live(jar).client
    }

    /// Asks one thing, saying it as it is sent and what came of it once it came -- `request` hands back what to
    /// say, a failure is said by its kind -- and then, unless told not to, what the television says its power is.
    private func ask(_ what: String, of client: ScalarClient, _ say: (String) -> Void, afterwards: Bool = true,
                     _ request: () async throws -> String) async {
        say("sending \(what)")
        let began = ContinuousClock.now
        let came: String
        do { came = try await request() } catch { came = TVSitting.said(error) }
        say("\(what): \(came) (\(String(format: "%.2f s", (ContinuousClock.now - began) / .seconds(1))))")
        if afterwards { await Self.sayingPower(of: client, say, "after it") }
    }

    fileprivate static func sayingPower(of client: ScalarClient, _ say: (String) -> Void, _ when: String) async {
        do { say("  power \(when): \(try await client.powerStatus())") } catch { say("  power \(when): \(TVSitting.said(error))") }
    }

    /// One page of a list, by the client's whole result for it: an answer that is not a page has its structure
    /// said, by types alone, before it is thrown as one that cannot be read.
    private static func page(_ asking: ContentAsking, _ index: Int, _ count: Int, of client: ScalarClient,
                             _ say: (String) -> Void, timeout: TimeInterval? = nil) async throws -> [[String: ScalarValue]] {
        let result = try await client.contentResult(version: asking.version, params: asking.params(index, count),
                                                    timeout: timeout)
        do {
            return try ScalarClient.contentRows(result)
        } catch {
            say("  not a page; its structure: \(RecordingRows.structure(of: result))")
            throw error
        }
    }

    /// What `request` hands back, or a failure said by its kind: an error as it came can carry the address.
    fileprivate static func sayingItsKind<T>(_ what: String, _ request: () async throws -> T) async throws -> T {
        do { return try await request() } catch { throw TVSitting.Stopped(what: "\(what): \(TVSitting.said(error))") }
    }

    /// Every row of a list, fifty at a time until a page is short, twenty pages at most.
    fileprivate static func everyRow(_ asking: ContentAsking,
                                     of client: ScalarClient) async throws -> [[String: ScalarValue]] {
        var rows: [[String: ScalarValue]] = []
        for _ in 0..<20 {
            let page = try await client.contentPage(version: asking.version, params: asking.params(rows.count, 50))
            rows += page
            if page.count < 50 { return rows }
        }
        throw TVSitting.Stopped(what: "the list did not end within twenty pages")
    }

    /// A line put out as it is said, not when the test ends.
    fileprivate static let sayAtOnce: @Sendable (String) -> Void = { line in
        print(line)
        fflush(stdout)
    }
}

/// How a content list, or its count, is asked for in one version: its parameters, with `source` or with `uri` as
/// the version's signature has it, and `target` `all` where the label says so, as it was first tried.
struct ContentAsking: Sendable {
    var label: String
    var method: String
    var version: String
    var byURI = false
    var targetAll = false

    var said: String { "\(method) \(label)" }

    func params(_ index: Int, _ count: Int) -> [String: ScalarValue] {
        var params: [String: ScalarValue] = [byURI ? "uri" : "source": .string(ScalarClient.recordingsSource)]
        if method == "getContentList" {
            params["stIdx"] = .int(index)
            params["cnt"] = .int(count)
        }
        if targetAll { params["target"] = "all" }
        return params
    }

    static let lists = [
        ContentAsking(label: "1.0", method: "getContentList", version: "1.0"),
        ContentAsking(label: "1.2", method: "getContentList", version: "1.2"),
        ContentAsking(label: "1.2+all", method: "getContentList", version: "1.2", targetAll: true),
        ContentAsking(label: "1.5", method: "getContentList", version: "1.5", byURI: true),
    ]

    static let counts = [
        ContentAsking(label: "1.0", method: "getContentCount", version: "1.0"),
        ContentAsking(label: "1.1", method: "getContentCount", version: "1.1"),
        ContentAsking(label: "1.1+all", method: "getContentCount", version: "1.1", targetAll: true),
    ]

    /// The list's asking `TV_CONTENT_VERSION` names; skipped without one.
    static func named() throws -> ContentAsking {
        let label = ProcessInfo.processInfo.environment["TV_CONTENT_VERSION"] ?? ""
        guard let asking = lists.first(where: { $0.label == label }) else {
            throw XCTSkip("Set TV_CONTENT_VERSION to one of \(lists.map(\.label).joined(separator: ", ")).")
        }
        return asking
    }
}

/// What is said of the rows of a list of recordings: their shape, and each by its start, its length and its short
/// values. A key is said only when it reads as a field's name, never as data used as a key; a value only when it is
/// a flag, a number or a short word, and never of a field that names the programme, the channel or the item.
enum RecordingRows {
    /// The fields whose values are said as they came: flags, never a text of the programme's.
    static let flags: Set<String> = ["isProtected", "isAlreadyPlayed", "isNew", "hasResume", "isAutoDelete",
                                     "isPlayable", "isBrowsable", "userContentFlag", "is3D", "is4K", "isPlaylist"]
    /// The fields asked after by name, said present or not in every list.
    static let asked = ["eventId", "description", "broadcastGenreInfo", "isNew", "hasResume", "position",
                        "recordingInfo", "stateInfo", "durationSec", "duration", "startDateTime", "isProtected"]
    /// What a field's name says it holds, by which its value is never said: the programme, the channel and its
    /// number, the item and where it is.
    private static let naming = ["uri", "title", "name", "num", "triplet", "desc", "label", "artist", "album",
                                 "genre", "text", "service", "freq", "product", "storage", "channel"]

    /// Each key, nested ones as `outer.inner` and those of a list's objects as `outer[].inner`, with how many rows
    /// have it and the types it came as; then the fields asked after, the form of the starts, the uris' forms and
    /// the names of their query's parameters, and the flags' values.
    static func shape(of rows: [[String: ScalarValue]]) -> [String] {
        var kinds: [String: Set<String>] = [:]
        var rowsWith: [String: Int] = [:]
        for row in rows {
            var seen: Set<String> = []
            walk(row) { path, value in
                kinds[path, default: []].insert(value.kind)
                seen.insert(path)
            }
            for path in seen { rowsWith[path, default: 0] += 1 }
        }
        var lines = kinds.keys.sorted().map { path in
            "key \(path): \(rowsWith[path] ?? 0) rows, \((kinds[path] ?? []).sorted().joined(separator: " or "))"
        }
        lines.append("asked after: " + asked.map { key in "\(key) \(rows.filter { $0[key] != nil }.count)" }
            .joined(separator: ", "))
        let starts = rows.compactMap { $0["startDateTime"] }.map { value -> String in
            guard case .string(let text) = value else { return "a \(value.kind)" }
            return startForm(text) + (RecorderTime.parse(text) == nil ? ", not read by the app" : "")
        }
        lines.append("starts written: " + (starts.isEmpty ? "none" : Set(starts).sorted().joined(separator: "; ")))
        var forms: Set<String> = [], lengths: [Int] = []
        for value in rows.compactMap({ $0["uri"] }) {
            guard case .string(let text) = value else {
                forms.insert("a \(value.kind)")
                continue
            }
            forms.insert(uriForm(text))
            lengths.append(text.count)
        }
        let distinct = Set(rows.compactMap { $0["uri"] }).count
        let spread = lengths.isEmpty ? "" : ", \(lengths.min() ?? 0) to \(lengths.max() ?? 0) characters long"
        lines.append("uris: " + (forms.isEmpty ? "none" : forms.sorted().joined(separator: "; "))
                     + spread + ", \(distinct) distinct of \(rows.filter { $0["uri"] != nil }.count)")
        for flag in flags.sorted() {
            let values = Set(rows.compactMap { $0[flag] }.map(said))
            if !values.isEmpty { lines.append("flag \(flag): \(values.sorted().joined(separator: ", "))") }
        }
        return lines
    }

    /// Each row by its place in the list, its start as a time of day in Japan, its length and whether it is
    /// protected, which is what a write is told which one to touch by; whether it has `recordingInfo` and
    /// `stateInfo`; and each of its values that is said at all (`shown(field:)`), nested ones too, by its key.
    static func each(_ rows: [[String: ScalarValue]]) -> [String] {
        rows.enumerated().map { index, row in
            var values: [String] = []
            walk(row) { path, value in
                switch value {
                case .object, .list: return
                default: break
                }
                guard let shown = shown(field: path, value) else { return }
                values.append("\(path)=\(shown)")
            }
            return "row \(index + 1): starts \(clock(of: row) ?? "-"), \(minutes(of: row).map { "\($0) min" } ?? "-"),"
                + " protected \(row["isProtected"].map(said) ?? "-"),"
                + " recordingInfo \(row["recordingInfo"] == nil ? "no" : "yes"),"
                + " stateInfo \(row["stateInfo"] == nil ? "no" : "yes")"
                + (values.isEmpty ? "" : "; " + values.sorted().joined(separator: " "))
        }
    }

    /// A value the television gave, by its structure and the types in it alone: what is said of an answer that
    /// is not a page.
    static func structure(of value: ScalarValue, depth: Int = 0) -> String {
        guard depth < 4 else { return value.kind }
        switch value {
        case .list(let items):
            return "list of \(items.count)" + (items.first.map { " [\(structure(of: $0, depth: depth + 1)), ...]" } ?? "")
        case .object(let fields):
            let inner = fields.keys.sorted().map { "\(key($0)): \(structure(of: fields[$0] ?? .null, depth: depth + 1))" }
            return "object {\(inner.joined(separator: ", "))}"
        default:
            return value.kind
        }
    }

    /// Every value of a row with its path, the row's own keys first and nested ones as `outer.inner` or
    /// `outer[].inner`, a key said as `<key>` unless it reads as a field's name.
    private static func walk(_ row: [String: ScalarValue], _ visit: (String, ScalarValue) -> Void) {
        func down(_ value: ScalarValue, at path: String) {
            visit(path, value)
            switch value {
            case .object(let fields): for (name, inner) in fields { down(inner, at: "\(path).\(key(name))") }
            case .list(let items): for item in items { down(item, at: "\(path)[]") }
            default: break
            }
        }
        for (name, value) in row { down(value, at: key(name)) }
    }

    /// A key as it came when it reads as a field's name -- a letter, then up to 31 letters, digits or `_` in
    /// ASCII -- and `<key>` otherwise: an object keyed by its data says nothing of that data.
    static func key(_ name: String) -> String {
        reads(name, maximum: 32) ? name : "<key>"
    }

    /// The form a start is written in, each digit as `d` and any other letter or sign but those of a date's form
    /// as `x`; then the offset from the twentieth character on, when it reads as one, `+09:00`, `+0900` or `Z`.
    static func startForm(_ text: String) -> String {
        let form = String(text.map { "-+:TZ .".contains($0) ? $0 : ($0.isASCII && $0.isNumber ? "d" : "x") })
        let tail = text.count > 19 ? String(text.dropFirst(19)) : ""
        let offset: String
        if tail.isEmpty {
            offset = "-"
        } else if tail == "Z" || isOffset(tail) {
            offset = tail
        } else {
            offset = "of another form"
        }
        return "\(form) offset \(offset)"
    }

    private static func isOffset(_ text: String) -> Bool {
        let characters = Array(text)
        guard characters.count == 5 || characters.count == 6, characters[0] == "+" || characters[0] == "-" else {
            return false
        }
        let digits = characters.count == 6 ? [1, 2, 4, 5] : [1, 2, 3, 4]
        return digits.allSatisfy { characters[$0].isASCII && characters[$0].isNumber }
            && (characters.count == 5 || characters[3] == ":")
    }

    /// A uri's form: its scheme when it reads as one -- a small letter, then up to fifteen small letters, digits,
    /// `+`, `.` or `-` -- the rest with each run of letters as `a`, of digits as `d` and of anything else outside
    /// ASCII as `x`, ASCII signs kept; and the names of its query's parameters that read as names, with how many
    /// others there are.
    static func uriForm(_ text: String) -> String {
        let scheme: String
        if let colon = text.firstIndex(of: ":") {
            let written = text[..<colon]
            let readsAsOne = written.first.map { $0.isASCII && $0.isLowercase } == true && written.count <= 16
                && written.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "+.-".contains($0)) }
            scheme = readsAsOne ? String(written) : "a scheme of another form"
        } else {
            scheme = "no scheme"
        }
        var names: [String] = [], others = 0
        if let mark = text.firstIndex(of: "?") {
            for item in text[text.index(after: mark)...].split(separator: "&", omittingEmptySubsequences: false) {
                if let equals = item.firstIndex(of: "="), reads(String(item[..<equals]), maximum: 24) {
                    names.append(String(item[..<equals]))
                } else {
                    others += 1
                }
            }
        }
        let parameters = names.isEmpty && others == 0 ? ""
            : " with \(names.joined(separator: ","))" + (others == 0 ? "" : " and \(others) other")
        return "\(scheme), \(masked(text))" + parameters
    }

    /// A text with each run of letters as `a`, each of digits as `d`, each of anything else outside ASCII as `x`,
    /// and ASCII signs as they are.
    static func masked(_ text: String) -> String {
        var form = ""
        for character in text {
            let mark: Character
            if character.isLetter {
                mark = "a"
            } else if character.isNumber {
                mark = "d"
            } else if character.isASCII {
                mark = character.isWhitespace ? "_" : character
            } else {
                mark = "x"
            }
            if "adx".contains(mark), form.last == mark { continue }
            form.append(mark)
        }
        return form
    }

    /// Whether a text reads as a name: a letter, then letters, digits or `_`, all in ASCII, `maximum` at most.
    private static func reads(_ name: String, maximum: Int) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter, name.count <= maximum else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// A row's start as HH:mm in Japan, nil when it gives none the app can read.
    static func clock(of row: [String: ScalarValue]) -> String? {
        guard case .string(let text)? = row["startDateTime"], let date = RecorderTime.parse(text) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = RecorderTime.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// When a row's recording ends, nil when it does not say.
    static func end(of row: [String: ScalarValue]) -> Date? {
        guard case .string(let text)? = row["startDateTime"], let start = RecorderTime.parse(text),
              let seconds = seconds(of: row) else { return nil }
        return start.addingTimeInterval(seconds)
    }

    static func minutes(of row: [String: ScalarValue]) -> Int? { seconds(of: row).map { Int($0 / 60) } }

    /// A row's length: `durationSec`, as 1.0 and 1.2 give it, or, from 1.5, which gives an object, `duration`,
    /// whose fields no answer has shown yet, a count in it named as seconds or as milliseconds.
    private static func seconds(of row: [String: ScalarValue]) -> TimeInterval? {
        if let seconds = number(row["durationSec"]) { return seconds }
        guard case .object(let fields)? = row["duration"] else { return nil }
        for name in ["durationSec", "seconds", "sec"] {
            if let seconds = number(fields[name]) { return seconds }
        }
        for name in ["durationMsec", "milliseconds", "msec"] {
            if let milliseconds = number(fields[name]) { return milliseconds / 1000 }
        }
        return nil
    }

    private static func number(_ value: ScalarValue?) -> TimeInterval? {
        switch value {
        case .int(let number)?: TimeInterval(number)
        case .double(let number)?: number
        default: nil
        }
    }

    /// Whether a row reads as protected, as a boolean or as the strings `true` and `false`; nil otherwise.
    static func protected(_ row: [String: ScalarValue]) -> Bool? {
        switch row["isProtected"] {
        case .bool(let flag)?: flag
        case .string("true")?: true
        case .string("false")?: false
        default: nil
        }
    }

    /// A flag's or a number's value as it came; anything else by its type alone.
    static func said(_ value: ScalarValue) -> String {
        switch value {
        case .bool(let flag): "\(flag)"
        case .int(let number): "\(number)"
        case .double(let number): "\(number)"
        case .string(let text) where text.count <= 12 && text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }):
            "\"\(text)\""
        default: "a \(value.kind)"
        }
    }

    /// A value of the field at `path` as `said` has it, nil when it is not to be said: the field's name says it
    /// names the programme, the channel or the item (`naming`), or its key is not a field's name, or `said` gives
    /// only its type.
    static func shown(field path: String, _ value: ScalarValue) -> String? {
        let name = (path.split(separator: ".").last.map(String.init) ?? path).replacingOccurrences(of: "[]", with: "")
        let lowered = name.lowercased()
        guard name != "<key>", !naming.contains(where: { lowered.contains($0) }), !lowered.hasSuffix("id"),
              !lowered.hasSuffix("no") else { return nil }
        let shown = said(value)
        return shown.hasPrefix("a ") ? nil : shown
    }
}

/// The steps of a write to the television's recordings, each followed by the list read again and what it says of
/// the recording: listed or not, protected or not, and how many rows the list holds and lost besides.
final class RecordingWrite {
    let client: ScalarClient
    let asking: ContentAsking
    let start: String
    let say: @Sendable (String) -> Void
    /// The uris the list held when the recording was found in it.
    private var listedBefore: Set<ScalarValue> = []
    /// Whether a protection was asked for and the list has not read the recording as unprotected, or gone, since.
    private(set) var mayBeLeftProtected = false

    init(client: ScalarClient, asking: ContentAsking, start: String, say: @escaping @Sendable (String) -> Void) {
        self.client = client
        self.asking = asking
        self.start = start
        self.say = say
    }

    /// The recording the owner named: exactly one that starts at `start`, has ended, and is protected as asked.
    /// A row that gives no length the app reads is taken as ended, since the television said it is recording
    /// nothing before the steps began. Its uri, which nothing prints. The list as it was read is said first.
    func target(protected: Bool) async throws -> String {
        let rows = try await LiveTVTests.sayingItsKind("the list") { try await LiveTVTests.everyRow(asking, of: client) }
        say("the list before: \(rows.count) rows")
        let named = rows.filter { RecordingRows.clock(of: $0) == start }
        guard named.count == 1, let row = named.first, case .string(let uri)? = row["uri"] else {
            throw XCTSkip("\(named.count) recordings with a uri start at \(start): exactly one is wanted")
        }
        if let end = RecordingRows.end(of: row) {
            guard end < Date() else { throw XCTSkip("the recording named has not ended") }
        } else {
            say("the recording named gives no length the app reads: taken as ended, as the television says"
                + " it is recording nothing")
        }
        guard let reads = RecordingRows.protected(row) else {
            throw XCTSkip("the recording named gives a protection the test does not read:"
                          + " \(row["isProtected"].map(RecordingRows.said) ?? "none")")
        }
        guard reads == protected else {
            throw XCTSkip("the recording named is not read as \(protected ? "protected" : "unprotected")")
        }
        listedBefore = Set(rows.compactMap { $0["uri"] })
        return uri
    }

    /// Protects the recording, or lifts that, and reads the list until it shows the change; what the list read
    /// of it last.
    @discardableResult
    func protect(_ uri: String, _ on: Bool) async throws -> Bool?? {
        if on { mayBeLeftProtected = true }
        let taken = await send("setDeleteProtection \(on)") { try await client.setDeleteProtection(uri: uri, on) }
        guard taken else { return try await read(uri) }
        return try await settle(uri) { $0 == Optional(Optional(on)) }
    }

    /// Deletes the recording and reads the list until it no longer has it; what the list read of it last, nil
    /// when it is gone.
    @discardableResult
    func delete(_ uri: String, _ what: String) async throws -> Bool?? {
        let taken = await send("\(what) (deleteContent)") { try await client.deleteContent(uri: uri) }
        guard taken else { return try await read(uri) }
        return try await settle(uri) { $0 == nil }
    }

    /// Sends the delete of a recording the list no longer has once more, and only once no list in any version
    /// has a row with its uri: what the television answers a delete of a uri it no longer has.
    func deleteAgain(_ uri: String) async throws {
        var listed = false
        for other in ContentAsking.lists {
            do {
                let rows = try await LiveTVTests.everyRow(other, of: client)
                let has = rows.contains { $0["uri"] == .string(uri) }
                if has { listed = true }
                say("  \(other.said): \(rows.count) rows, the recording \(has ? "listed" : "not listed")")
            } catch {
                say("  \(other.said): \(TVSitting.said(error))")
            }
        }
        guard !listed else {
            say("listed in a version: the delete is not sent again")
            return XCTFail("the recording is still listed in a version after its delete")
        }
        try await delete(uri, "the same delete again")
    }

    /// Says, when a protection may be left on, that it is to be lifted with the remote.
    func sayIfLeftProtected() {
        if mayBeLeftProtected { say("the protection may be left on: lift it with the remote") }
    }

    /// The list read again and said: whether it holds the recording, as protected or not (nil when it is not
    /// listed), and how many rows it holds and how many of those listed before, besides the recording, it no
    /// longer has.
    @discardableResult
    func read(_ uri: String) async throws -> Bool?? {
        let (state, line) = try await look(uri)
        say(line)
        return state
    }

    /// The list read every two seconds, twenty at most, until `done` says what it read of the recording is the
    /// change, and said once with the seconds that took.
    private func settle(_ uri: String, until done: (Bool??) -> Bool) async throws -> Bool?? {
        let began = ContinuousClock.now
        while true {
            let (state, line) = try await look(uri)
            let waited = ContinuousClock.now - began
            if done(state) || waited >= .seconds(20) {
                let seconds = String(format: "%.1f s", waited / .seconds(1))
                say(line + (done(state) ? " (after \(seconds))" : " (no change after \(seconds))"))
                return state
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    private func look(_ uri: String) async throws -> (state: Bool??, line: String) {
        let rows = try await LiveTVTests.sayingItsKind("the list") { try await LiveTVTests.everyRow(asking, of: client) }
        let row = rows.first { $0["uri"] == .string(uri) }
        let now = Set(rows.compactMap { $0["uri"] })
        let lost = listedBefore.subtracting(now).subtracting([.string(uri)]).count
        let state = row.map(RecordingRows.protected)
        if row == nil || state == Optional(Optional(false)) { mayBeLeftProtected = false }
        return (state, "  the list: \(rows.count) rows, the recording \(row == nil ? "not listed" : "listed"),"
            + " protected \(row.flatMap(RecordingRows.protected).map { "\($0)" } ?? "-"), others gone \(lost)")
    }

    /// Sends one write, says what came of it and then the power status; whether it was taken.
    private func send(_ what: String, _ request: () async throws -> Void) async -> Bool {
        say("sending \(what)")
        let began = ContinuousClock.now
        let came: String
        var taken = false
        do {
            try await request()
            came = "taken"
            taken = true
        } catch {
            came = TVSitting.said(error)
        }
        say("\(what): \(came) (\(String(format: "%.2f s", (ContinuousClock.now - began) / .seconds(1))))")
        await LiveTVTests.sayingPower(of: client, say, "after it")
        return taken
    }
}
