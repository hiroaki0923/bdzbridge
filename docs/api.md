# HTTP API

bdzbridge のサーバーが提供する JSON API の一覧です。`bdzbridge/tools/apidoc.py` が OpenAPI 記述から生成します（手で編集しないでください。サーバーを起動すると `/docs` で同じ内容を対話的に試せます）。

すべてのリクエストに `Authorization: Bearer <BDZBRIDGE_API_TOKEN>` が必要です。パスの先頭は `/api/v1` です。

## レコーダー

### GET /recorders/discover

Sony recorders answering on the LAN (SSDP, then a port scan of the local /24).

レスポンス:
- 200: `list[RecorderCandidate]`

### GET /recorder

The selected recorder: model, power and playback state, HDD space, guide cache summary. `reachable` is false while it is off the network.

レスポンス:
- 200: `RecorderStatus`

### PUT /recorder

Use this recorder from now on; the choice is saved and the guide is refreshed in the background.

リクエスト本文: `RecorderSelect`

レスポンス:
- 200: `RecorderStatus`

### POST /recorder/wake

Wake-on-LAN for a recorder that has dropped off the network.

レスポンス:
- 200: `WakeResult`

### POST /recorder/power

Switch the recorder fully on (Wake-on-LAN first when it does not answer).

レスポンス:
- 200: `PowerResult`

### GET /defaults

Default quality and repeat plus the label tables the web app uses (qualities, repeats, broadcasting types, genres).

レスポンス:
- 200: `Defaults`

### POST /epg/refresh

Re-download the guide from the recorder now; the auto-reservation rules and the monitor run afterwards.

レスポンス:
- 200: `dict`

## 番組表

### GET /channels

Channels

パラメータ:
- `broadcasting` (query): "td" | "bs" | "cs" | "bs4k" | "cs4k" | null
- `include_hidden` (query): boolean、既定 `false` — also the channels the user has hidden

レスポンス:
- 200: `list[Channel]`

### PUT /channels/{broadcasting}/prefs

Hide channels and/or reorder them; returns every channel of that type, hidden ones included.

パラメータ:
- `broadcasting` (path): "td" | "bs" | "cs" | "bs4k" | "cs4k"

リクエスト本文: `ChannelPrefs`

レスポンス:
- 200: `list[Channel]`

### GET /programs

Programs

パラメータ:
- `broadcasting` (query): "td" | "bs" | "cs" | "bs4k" | "cs4k" | null
- `service_id` (query): integer | null
- `date` (query): string | null — YYYY-MM-DD; TV day 04:00-04:00 JST
- `since` (query): datetime | null
- `until` (query): datetime | null
- `q` (query): string | null
- `compact` (query): boolean、既定 `false` — omit description/extended (for the grid view)
- `include_hidden` (query): boolean、既定 `false` — include programs of channels the user has hidden
- `limit` (query): integer、既定 `500`
- `offset` (query): integer、既定 `0`

レスポンス:
- 200: `list[Program]`

### GET /programs/now

What is on air right now on every channel of one broadcasting type.

パラメータ:
- `broadcasting` (query): "td" | "bs" | "cs" | "bs4k" | "cs4k"、既定 `"td"`

レスポンス:
- 200: `list[Program]`

### GET /programs/{broadcasting}/{service_id}/{event_id}

One programme of the cached guide by its ARIB event id.

パラメータ:
- `broadcasting` (path): "td" | "bs" | "cs" | "bs4k" | "cs4k"
- `service_id` (path): integer
- `event_id` (path): integer

レスポンス:
- 200: `Program`

## 予約

### GET /reservations

Every reservation on the recorder, with the programme's genres when the guide still has it.

レスポンス:
- 200: `list[Reservation]`

### POST /reservations

Create a reservation. With `event_id` the recorder follows schedule changes and uses its own title; without it give `start`, `duration_sec` and `title`. Answers 409 with the conflicts unless `force` is set, and 422 when a weekly repeat names a weekday other than the programme's.

リクエスト本文: `ReservationCreate`

レスポンス:
- 201: `ReservationCreated`

### POST /reservations/check

Ask the recorder which existing reservations a new one would conflict with, without creating it.

リクエスト本文: `ReservationCreate`

レスポンス:
- 200: `ConflictReport`

### PATCH /reservations/{reservation_id}

Change quality or repeat (and, for time-based reservations, title, start and duration).

パラメータ:
- `reservation_id` (path): string

リクエスト本文: `ReservationUpdate`

レスポンス:
- 200: `Reservation`

### DELETE /reservations/{reservation_id}

Delete a reservation.

パラメータ:
- `reservation_id` (path): string

レスポンス:
- 204: 本文なし

## 自動予約・通知・監視

### GET /rules

The keyword auto-reservation rules.

レスポンス:
- 200: `list[Rule]`

### POST /rules

Rule Create

パラメータ:
- `run` (query): boolean、既定 `false` — apply every rule right away (reserves on the recorder)

リクエスト本文: `RuleCreate`

レスポンス:
- 201: `Rule`

### GET /rules/log

Rules Log

パラメータ:
- `limit` (query): integer、既定 `50`

レスポンス:
- 200: `list[AutoLogEntry]`

### POST /rules/run

Apply every enabled rule now (they also run after each guide refresh); reports what was reserved.

レスポンス:
- 200: `AutoRunResult`

### GET /rules/{rule_id}/matches

Upcoming programs the rule matches (reserved or not).

パラメータ:
- `rule_id` (path): integer

レスポンス:
- 200: `list[Program]`

### PATCH /rules/{rule_id}

Enable or disable a rule, or change its quality or title-only matching.

パラメータ:
- `rule_id` (path): integer

リクエスト本文: `RuleUpdate`

レスポンス:
- 200: `Rule`

### DELETE /rules/{rule_id}

Delete a rule and its log.

パラメータ:
- `rule_id` (path): integer

レスポンス:
- 204: 本文なし

### GET /recorder-rules

The keyword conditions held by the recorder itself (おまかせ・まる録). These record without this server. The channel narrowing set on the recorder's screen is not reported.

レスポンス:
- 200: `list[RecorderRule]`

### POST /recorder-rules

Register a condition on the recorder itself. The recorder composes the name; the channel cannot be set this way.

リクエスト本文: `RecorderRuleCreate`

レスポンス:
- 201: `RecorderRule`

### DELETE /recorder-rules/{rule_id}

Remove a condition from the recorder, whoever made it. Ids change whenever the recorder's screen edits a condition, so read the list first.

パラメータ:
- `rule_id` (path): string

レスポンス:
- 204: 本文なし

### POST /monitor/run

Check free space and conflicting reservations now (normally runs after every EPG refresh).

レスポンス:
- 200: `MonitorResult`

### GET /notify

Which notification channels are configured (SMTP, webhook) and the free-space warning threshold.

レスポンス:
- 200: `NotifyStatus`

### POST /notify/test

Send a test message through every configured channel.

レスポンス:
- 200: `NotifyStatus`

## 録画

### GET /titles

Titles

パラメータ:
- `limit` (query): integer、既定 `100`
- `offset` (query): integer、既定 `0`
- `series` (query): string | null — only titles with this grouping key (see /titles/groups)

レスポンス:
- 200: `list[RecordedTitle]`

### GET /titles/groups

Recorded titles grouped into programmes by their names, newest group first.

パラメータ:
- `genre` (query): integer | null — ARIB level-1 genre code
- `refresh` (query): boolean、既定 `false` — re-read the title list from the recorder

レスポンス:
- 200: `list[TitleGroup]`

### POST /titles/delete

Start deleting several recordings (a few seconds each); poll GET /jobs/{id}, cancel with POST /jobs/{id}/cancel.
Protected and unknown ids are skipped, not failed.

リクエスト本文: `TitlesDelete`

レスポンス:
- 202: `Job`

### POST /titles/protect

Start protecting or unprotecting several recordings; poll GET /jobs/{id}.

リクエスト本文: `TitlesProtect`

レスポンス:
- 202: `Job`

### POST /titles/duplicates

Start looking for recordings that are copies of one broadcast; poll GET /jobs/{id} for the sets.

レスポンス:
- 202: `Job`

### GET /recorder/playback

What the recorder is playing on the TV connected to it.

レスポンス:
- 200: `PlaybackStatus`

### POST /recorder/playback

Pause, resume or stop the recorder's own playback (`resume` only while paused).

リクエスト本文: `PlaybackControl`

レスポンス:
- 200: `PlaybackStatus`

### POST /titles/{title_id}/play

Start playing a recorded title on the TV connected to the recorder.

パラメータ:
- `title_id` (path): string
- `position_sec` (query): integer、既定 `0`

レスポンス:
- 200: `PlaybackStatus`

### PATCH /titles/{title_id}

Protect / unprotect a recording, clear its NEW mark, or rename it.

パラメータ:
- `title_id` (path): string

リクエスト本文: `TitleUpdate`

レスポンス:
- 200: `TitleFlags`

### DELETE /titles/{title_id}

Delete a recording. This is final; the recorder refuses protected titles and ones being recorded.

パラメータ:
- `title_id` (path): string

レスポンス:
- 204: 本文なし

### GET /titles/{title_id}

The programme text of one recording (summary and detail paragraphs).

パラメータ:
- `title_id` (path): string

レスポンス:
- 200: `TitleDetail`

## バックグラウンドジョブ

### GET /jobs

Running jobs first, then the recently finished ones; lets a reopened page pick up what is still going on.

レスポンス:
- 200: `list[Job]`

### GET /jobs/{job_id}

Progress and, once finished, the result of a bulk job.

パラメータ:
- `job_id` (path): string

レスポンス:
- 200: `Job`

### POST /jobs/{job_id}/cancel

Stop after the item being processed; what is done stays done.

パラメータ:
- `job_id` (path): string

レスポンス:
- 200: `Job`

## モデル

### RecorderCandidate

- `host`: string
- `port`: integer
- `friendly_name`: string
- `product`: string
- `model`: string
- `udn`: string
- `epg_capable`: boolean
- `location`: string
- `via`: string
- `selected`: boolean （省略可、既定 `false`）

### RecorderStatus

- `configured`: boolean
- `host`: string | null （省略可）
- `friendly_name`: string | null （省略可）
- `model`: string | null （省略可）
- `product`: string | null （省略可）
- `epg_capable`: boolean | null （省略可）
- `udn`: string | null （省略可）
- `firmware`: string | null （省略可）
- `power`: string | null （省略可）
- `play`: string | null （省略可）
- `storage`: Storage | null （省略可）
- `reachable`: boolean | null （省略可） — False when the recorder is not answering on the network (try POST /recorder/wake)
- `mac`: string | null （省略可）
- `epg`: dict

### Storage

- `destination`: string （省略可、既定 `"HDD"`）
- `total_bytes`: integer
- `free_bytes`: integer

### RecorderSelect

- `host`: string

### WakeResult

- `awake`: boolean — the reservation service answers after the magic packets
- `mac`: string | null

### PowerResult

- `power`: string — the recorder's reply to X_PowerControl, normally PowerOn

### Defaults

- `quality`: "DR" | "XR" | "XSR" | "SR" | "LSR" | "LR" | "ER" | "EER"
- `repeat`: "none" | "title" | "daily" | "mon" | "tue" | "wed" | "thu" | "fri" | "sat" | "sun" | "mon-fri" | "mon-sat"
- `qualities`: dict[str, string]
- `repeats`: dict[str, string]
- `broadcastings`: dict[str, string]
- `genres`: dict[str, string] （省略可） — ARIB level-1 genre code → label
- `sub_genres`: dict[str, dict[str, string]] （省略可） — ARIB level-1 genre code → sub-genre code → label

### Channel

- `broadcasting`: "td" | "bs" | "cs" | "bs4k" | "cs4k"
- `service_id`: integer
- `name`: string
- `sort`: integer
- `logo`: string | null （省略可） — station logo as a data: URL (64x36 PNG from the recorder)
- `hidden`: boolean （省略可、既定 `false`）

### ChannelPrefs

- `order`: list[integer] | null （省略可） — service ids in the wanted order; [] restores the recorder's order
- `hidden`: list[integer] | null （省略可） — service ids to hide from the guide and search; [] shows all

### Program

- `broadcasting`: "td" | "bs" | "cs" | "bs4k" | "cs4k"
- `service_id`: integer
- `service_name`: string
- `event_id`: integer
- `start`: datetime
- `end`: datetime
- `duration_sec`: integer
- `title`: string
- `description`: string
- `extended`: string （省略可、既定 `""`）
- `genres`: list[Genre]
- `copy_control`: integer
- `parental_rating`: integer
- `is_reference`: boolean （省略可、既定 `false`）
- `ref_service_id`: integer | null （省略可）
- `ref_event_id`: integer | null （省略可）

### Genre

- `level1`: integer
- `level2`: integer | null — None stands for the whole level-1 genre, as a recorder condition can
- `label`: string
- `label2`: string | null （省略可） — the sub-genre's name; absent for a whole genre or an unused code

### Reservation

- `id`: string
- `title`: string
- `start`: datetime
- `end`: datetime
- `duration_sec`: integer
- `broadcasting`: string
- `service_id`: integer
- `service_name`: string | null （省略可）
- `event_id`: integer | null
- `tracks_program`: boolean
- `repeat`: string
- `repeat_label`: string
- `quality`: string
- `quality_label`: string
- `recording`: boolean
- `conflict`: boolean
- `destination`: string
- `size_mb`: integer | null
- `created_by_app`: boolean
- `created_by_recorder`: boolean （省略可、既定 `false`） — レコーダー自身が入れた予約（おまかせ録画）。消してもレコーダーが入れ直す
- `genres`: list[Genre] （省略可） — from the EPG cache when the reservation tracks a program that is still in it

### ReservationCreate

- `broadcasting`: "td" | "bs" | "cs" | "bs4k" | "cs4k"
- `service_id`: integer
- `event_id`: integer | null （省略可） — ARIB event_id; when given, start/duration/title come from the EPG unless overridden
- `start`: datetime | null （省略可）
- `duration_sec`: integer | null （省略可）
- `title`: string | null （省略可） — used for time-based reservations; with event_id the recorder replaces it with the EPG title
- `quality`: "DR" | "XR" | "XSR" | "SR" | "LSR" | "LR" | "ER" | "EER" | null （省略可）
- `repeat`: "none" | "title" | "daily" | "mon" | "tue" | "wed" | "thu" | "fri" | "sat" | "sun" | "mon-fri" | "mon-sat" | null （省略可）
- `force`: boolean （省略可、既定 `false`） — create even if the conflict check reports overlapping reservations

### ReservationCreated

- `reservation`: Reservation
- `conflicts`: list[Reservation]

### ConflictReport

- `conflicts`: list[Reservation]
- `ok`: boolean

### ReservationUpdate

- `quality`: "DR" | "XR" | "XSR" | "SR" | "LSR" | "LR" | "ER" | "EER" | null （省略可）
- `repeat`: "none" | "title" | "daily" | "mon" | "tue" | "wed" | "thu" | "fri" | "sat" | "sun" | "mon-fri" | "mon-sat" | null （省略可）
- `title`: string | null （省略可） — time-based reservations only
- `start`: datetime | null （省略可） — time-based reservations only
- `duration_sec`: integer | null （省略可） — time-based reservations only

### Rule

- `id`: integer
- `query`: string
- `broadcasting`: "td" | "bs" | "cs" | "bs4k" | "cs4k" | null （省略可）
- `service_id`: integer | null （省略可）
- `service_name`: string | null （省略可）
- `title_only`: boolean
- `quality`: "DR" | "XR" | "XSR" | "SR" | "LSR" | "LR" | "ER" | "EER"
- `enabled`: boolean
- `created`: datetime

### RuleCreate

- `query`: string — matched case-insensitively (NFKC) against the title, or title + description
- `broadcasting`: "td" | "bs" | "cs" | "bs4k" | "cs4k" | null （省略可）
- `service_id`: integer | null （省略可）
- `title_only`: boolean （省略可、既定 `true`）
- `quality`: "DR" | "XR" | "XSR" | "SR" | "LSR" | "LR" | "ER" | "EER" | null （省略可）

### AutoLogEntry

- `id`: integer
- `rule_id`: integer
- `rule_query`: string | null （省略可）
- `broadcasting`: string
- `service_id`: integer
- `event_id`: integer
- `title`: string
- `start`: datetime
- `status`: "reserved" | "conflict" | "error"
- `message`: string | null （省略可）
- `at`: datetime

### AutoRunResult

- `rules`: integer
- `checked`: integer
- `reserved`: integer
- `conflicts`: integer
- `errors`: integer
- `notified`: list[string] （省略可） — channels that delivered the report: email, webhook
- `at`: datetime | null （省略可）

### RuleUpdate

- `enabled`: boolean | null （省略可）
- `quality`: "DR" | "XR" | "XSR" | "SR" | "LSR" | "LR" | "ER" | "EER" | null （省略可）
- `title_only`: boolean | null （省略可）

### RecorderRule

- `id`: string
- `name`: string — composed by the recorder from the genre and the keywords
- `keywords`: list[string]
- `excluded`: list[string]
- `logic`: string
- `logic_label`: string
- `genres`: list[Genre]
- `time_scope`: string
- `time_scope_label`: string
- `broadcasting_scope`: string
- `broadcasting_scope_label`: string
- `quality`: string | null — 録画モード(地上/BS/CS)
- `quality_4k`: string | null — 録画モード(BS4K/CS4K), filled in by the recorder
- `destination`: string

### RecorderRuleCreate

A condition for the recorder's own おまかせ・まる録, which then records by it without this server. The
channel narrowing the recorder's screen offers cannot be set over the LAN.

- `keywords`: list[string] （省略可） — as the recorder's own screen allows: up to 5; a genre alone is also a condition
- `excluded`: list[string] （省略可） — up to 2
- `logic`: "OR" | "AND" （省略可、既定 `"OR"`）
- `genre_level1`: integer | null （省略可） — ARIB level-1 genre; alone it means the whole genre
- `genre_level2`: integer | null （省略可） — the sub-genre within level1
- `time_scope`: string （省略可、既定 `"ALL"`） — ALL, MORNING, AFTERNOON, NIGHT, MIDNIGHT
- `broadcasting_scope`: string （省略可、既定 `"ALL"`） — ALL, TRD, BSD, CSD, ADVBSD, ADVCSD; an unknown value widens to ALL on the recorder
- `quality`: "DR" | "XR" | "XSR" | "SR" | "LSR" | "LR" | "ER" | "EER" | null （省略可）

### MonitorResult

- `free_gb`: number | null （省略可）
- `low_space`: boolean
- `new_conflicts`: list[string]
- `notified`: list[string]

### NotifyStatus

- `configured`: boolean
- `email`: boolean
- `webhook`: boolean
- `to`: string | null （省略可）
- `free_gb`: number | null （省略可） — low-space warning threshold, 0 = off
- `sent`: list[string] （省略可）

### RecordedTitle

- `id`: string
- `title`: string
- `start`: datetime
- `duration_sec`: integer
- `broadcasting`: string
- `service_id`: integer
- `service_name`: string | null （省略可）
- `quality`: string
- `protected`: boolean
- `is_new`: boolean
- `recording`: boolean （省略可、既定 `false`） — the recorder is still writing to this one; it refuses to delete it
- `destination`: string
- `size_mb`: integer | null
- `dlna_id`: string — the title's DLNA object id on the recorder
- `genres`: list[Genre] （省略可） — from the recorder's genreID
- `series`: string （省略可、既定 `""`） — grouping key derived from the title (episodes of one programme share it)
- `last_played`: datetime | null （省略可）
- `resume_sec`: integer | null （省略可） — where playback stopped last time, 0 when it ran to the end
- `watch_state`: "unwatched" | "partway" | "watched" （省略可、既定 `"unwatched"`）

### TitleGroup

- `key`: string
- `name`: string
- `count`: integer
- `size_mb`: integer
- `latest`: datetime
- `earliest`: datetime
- `protected_count`: integer
- `new_count`: integer

### TitlesDelete

- `ids`: list[string]

### Job

A background job. Poll GET /jobs/{id}; POST /jobs/{id}/cancel stops it after the current item.

- `id`: string
- `kind`: "delete" | "protect" | "duplicates"
- `total`: integer
- `done`: integer
- `finished`: boolean
- `cancelled`: boolean
- `error`: string | null （省略可）
- `result`: dict （省略可） — delete: deleted/skipped; protect: changed/skipped; duplicates: sets

### TitlesProtect

- `ids`: list[string]
- `protected`: boolean

### PlaybackStatus

- `power`: string | null （省略可）
- `play`: string | null （省略可）
- `title_id`: string | null （省略可）
- `position_sec`: integer | null （省略可）
- `chapter`: integer | null （省略可）

### PlaybackControl

- `operation`: "stop" | "pause" | "resume" — resume is only valid while paused

### TitleUpdate

- `protected`: boolean | null （省略可） — protect from deletion (the recorder's 保護)
- `is_new`: boolean | null （省略可）
- `title`: string | null （省略可）

### TitleFlags

- `id`: string
- `protected`: boolean | null （省略可）
- `is_new`: boolean | null （省略可）
- `title`: string | null （省略可）

### TitleDetail

- `id`: string
- `summary`: string （省略可、既定 `""`）
- `details`: list[string] （省略可、既定 `[]`）
