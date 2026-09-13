"""Group recorded titles into programmes by their names.

The recorder does not say which reservation produced a title, so episodes of one programme can only be
recognised by their titles: broadcast marks ([字], [再], ...) are dropped, the text is cut at the first episode
marker (第３話, ＃１２, （３５）, 後編, ...) or, failing that, at the first subtitle separator (full-width space,
▽, 「…」), and the remainder is normalised into a key.
"""
from __future__ import annotations

import re
import unicodedata

_PUA = re.compile(r"[-]")
_MARKS = re.compile(r"\[(?:字|解|再|新|終|デ|二|多|SS|映|生|手|4K|HDR|5\.1|7\.1|22\.2|3D|2K|8K)\]")
_EPISODE = re.compile(
    r"(?:"
    r"第\s*[0-9０-９〇一二三四五六七八九十百]+\s*(?:話|回|夜|章|部|集|弾|幕|日目|週)"
    r"|[#＃]\s*[0-9０-９]+"
    r"|[（(]\s*[0-9０-９]+\s*[)）]"
    r"|(?<![0-9０-９])[0-9０-９]{1,3}\s*(?:話|回目?)(?![0-9０-９])"
    r"|(?<![a-zA-Z])(?:ep|episode|season)(?![a-zA-Z])|シーズン|前編|後編|総集編|最終回"
    r")",
    re.IGNORECASE,
)
_SEPARATORS = re.compile(r"[　▽▼▲△◆◇■□●○★☆※…：／｜～〜]")
# frames whose "「…」" part is the programme itself (日曜劇場「VIVANT」), not an episode subtitle
_FRAMES = {"日曜劇場", "土曜ドラマ", "金曜ドラマ", "木曜劇場", "火曜ドラマ", "水曜ドラマ", "月曜ドラマ", "連続テレビ小説", "大河ドラマ",
           "夜ドラ", "ドラマ１０", "ドラマ10", "プレミアムドラマ", "土曜時代ドラマ", "アニメ", "映画", "シネマ", "特集ドラマ", "スペシャルドラマ"}
_OPENERS = (("「", "」"), ("『", "』"), ("【", "】"), ("（", "）"), ("(", ")"), ("〔", "〕"))
_TRAIL = re.compile(r"[\s　\-－‐–—・･、,，。．.「『【〔（(\[]+$")


def _clean(title: str) -> str:
    return _MARKS.sub("", _PUA.sub("", title)).strip()


def _drop_subtitle_brackets(t: str) -> str:
    """'パウ・パトロール「ピカピカ…」' → 'パウ・パトロール'; frames like '日曜劇場「VIVANT」' are kept whole."""
    i = t.find("「")
    if i < 2:
        return t
    head = t[:i].strip()
    if head in _FRAMES or head.split("　")[-1] in _FRAMES:
        j = t.find("」", i)
        return t[:j + 1] if j > 0 else t
    return head


def series_name(title: str) -> str:
    """The part of a title that names the programme, for display."""
    t = _clean(title)
    m = _EPISODE.search(t)
    if m and m.start() > 0:
        t = t[:m.start()]
    elif m is None:
        parts = _SEPARATORS.split(t)
        if len(parts) >= 2 and parts[0].strip():
            head = parts[0]
            # a generic prefix (アニメ, 映画, 再放送 …) names nothing on its own: keep the next segment too
            if len(head.strip()) <= 4 and parts[1].strip():
                head = t[:len(parts[0]) + 1 + len(parts[1])]
            t = head
        t = _drop_subtitle_brackets(t)
    t = _TRAIL.sub("", t).strip()
    # an opener without its closer means the cut landed inside a bracket: drop that bracket
    for open_, close in _OPENERS:
        if t.count(open_) > t.count(close):
            t = t.rsplit(open_, 1)[0].strip() or t
    return t or _clean(title) or title


def series_key(title: str) -> str:
    """Normalised grouping key: NFKC, case-folded, without spaces."""
    name = unicodedata.normalize("NFKC", series_name(title)).casefold()
    return re.sub(r"\s+", "", name)


def same_title_key(title: str) -> str:
    """Key for 'the same programme title' (marks and spacing ignored): copies of one broadcast share it."""
    return re.sub(r"[\s　]+", "", unicodedata.normalize("NFKC", _clean(title)).casefold())


def summary_key(summary: str) -> str:
    """Programme descriptions compared loosely: marks, spaces and re-broadcast notes ignored."""
    t = unicodedata.normalize("NFKC", _clean(summary or "")).casefold()
    t = re.sub(r"[（(]?再放送[)）]?|\[再\]", "", t)
    return re.sub(r"[\s　]+", "", t)[:200]
