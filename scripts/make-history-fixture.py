#!/usr/bin/env python3
"""Writes a fake Spotify data export, the same every time for the same seed.

Both export kinds Spotify sends, in the folders it uses:
  Spotify Extended Streaming History/Streaming_History_Audio_*.json   (ts, ms_played, ...)
  Spotify Extended Streaming History/Streaming_History_Video_*.json
  Spotify Account Data/StreamingHistory_music_N.json                  (endTime, msPlayed, ...)
  Spotify Account Data/StreamingHistory_podcast_N.json
  MyData/endsong_0.json                                               (the older name)

Edge cases on purpose: clock changes, plays around New Year in many time zones, ms_played
of 0, 1, 29999, 30000 and 30001, podcasts, rows with null names, audiobook and empty rows,
an ad row, the same title by different artists, Cyrillic, CJK, Arabic and emoji names,
duplicate rows, files that overlap, the past year in both formats, and ip_addr,
conn_country and platform in every extended row (Tonearm must never store them).

Usage: make-history-fixture.py OUT_DIR [--rows N] [--seed S] [--zip FILE] [--extended-only]
"""
import argparse
import bisect
import json
import os
import random
import zipfile
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

UTC = timezone.utc
START = datetime(2019, 1, 1, tzinfo=UTC)
END = datetime(2025, 11, 30, tzinfo=UTC)
# Private network values, so nothing looks like a real person.
IP_PREFIX = "192.0.2."
COUNTRY = "ZZ"
PLATFORM = "OS X 14.5.0 [arm 2] fixture-platform"

SPECIAL_ARTISTS = [
    "Кино", "Сплин", "Земфира", "Ёлка", "坂本龍一", "宇多田ヒカル", "아이유", "王菲",
    "🌊 Wave Machine", "Sigur Rós", "Beyoncé", "Mötley Crüe", "سامي يوسف", "Café Tacvba",
    "Yulduz Usmonova", "The 1975", "!!!", "Ólafur Arnalds",
]
WORDS = [
    "night", "river", "glass", "summer", "echo", "paper", "golden", "static", "blue", "ghost",
    "city", "fire", "slow", "north", "light", "heart", "wire", "dream", "salt", "orbit",
    "звезда", "город", "ночь", "夜", "海", "光", "사랑", "✨", "моя", "hollow", "velvet", "signal",
]
COMMON_TITLES = ["Intro", "Home", "Untitled", "Outro", "Интро", "Interlude"]
REASON_START = ["trackdone", "clickrow", "fwdbtn", "backbtn", "playbtn", "appload"]
REASON_END = ["trackdone", "fwdbtn", "endplay", "logout", "unexpected-exit"]


def b62(rng, n=22):
    chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    return "".join(rng.choice(chars) for _ in range(n))


def ts_string(ms):
    return datetime.fromtimestamp(ms // 1000, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def end_time_string(ms):
    return datetime.fromtimestamp(ms // 1000, UTC).strftime("%Y-%m-%d %H:%M")


def utc_ms(dt):
    return int((dt - datetime(1970, 1, 1, tzinfo=UTC)) / timedelta(milliseconds=1))


class Catalog:
    def __init__(self, rng, n_artists):
        self.rng = rng
        names = list(SPECIAL_ARTISTS)
        while len(names) < n_artists:
            name = " ".join(w.capitalize() for w in rng.sample(WORDS, rng.choice([1, 2, 2, 3])))
            if name not in names:
                names.append(name)
        self.tracks = []  # (title, artist, album, uri, duration_ms)
        self.by_artist = []
        for artist in names:
            mine = []
            for _ in range(rng.choice([1, 1, 2, 3, 4])):
                album = " ".join(rng.sample(WORDS, 2)).title()
                for _ in range(rng.randint(4, 12)):
                    if rng.random() < 0.08:
                        title = rng.choice(COMMON_TITLES)
                    else:
                        title = " ".join(rng.sample(WORDS, rng.choice([1, 2, 3]))).capitalize()
                    track = (title, artist, album, "spotify:track:" + b62(rng), rng.randint(90_000, 420_000))
                    mine.append(track)
                    self.tracks.append(track)
            self.by_artist.append(mine)
        # Artists appear over time, so every year has new ones: 40% from the start, the rest
        # spread evenly until the end.
        n = len(names)
        start, end = utc_ms(START), utc_ms(END)
        self.debut = [start if i < n * 0.4 else start + (end - start) * (i - n * 0.4) / (n * 0.6) for i in range(n)]
        self.cum = []
        total = 0.0
        for i in range(n):
            total += 1 / (i + 1) ** 0.9
            self.cum.append(total)
        self.shows = []
        for s in range(8):
            show = ["Daily News", "Подкаст о кино", "テック話", "Deep Dive", "History Hour",
                    "Code Talk", "Сказки на ночь", "Slow French"][s]
            eps = [("Episode %d: %s" % (e + 1, " ".join(rng.sample(WORDS, 2))), show,
                    "spotify:episode:" + b62(rng), rng.randint(1_200_000, 5_400_000)) for e in range(40)]
            self.shows.append(eps)

    def pick_track(self, now=None):
        available = len(self.by_artist) if now is None else max(1, bisect.bisect_right(self.debut, now))
        r = self.rng.random() * self.cum[available - 1]
        artist = min(bisect.bisect_left(self.cum, r), available - 1)
        return self.rng.choice(self.by_artist[artist])

    def pick_episode(self):
        return self.rng.choice(self.rng.choice(self.shows))


def extended_row(rng, end_ms, ms, track=None, episode=None):
    row = {
        "ts": ts_string(end_ms),
        "platform": PLATFORM,
        "ms_played": ms,
        "conn_country": COUNTRY,
        "ip_addr": IP_PREFIX + str(rng.randint(1, 254)),
        "master_metadata_track_name": None,
        "master_metadata_album_artist_name": None,
        "master_metadata_album_album_name": None,
        "spotify_track_uri": None,
        "episode_name": None,
        "episode_show_name": None,
        "spotify_episode_uri": None,
        "audiobook_title": None,
        "audiobook_uri": None,
        "audiobook_chapter_uri": None,
        "audiobook_chapter_title": None,
        "reason_start": rng.choice(REASON_START),
        "reason_end": "trackdone" if track and ms >= track[4] else rng.choice(REASON_END),
        "shuffle": rng.random() < 0.4,
        "skipped": ms < 30_000,
        "offline": rng.random() < 0.05,
        "offline_timestamp": (end_ms // 1000) if rng.random() < 0.5 else None,
        "incognito_mode": rng.random() < 0.02,
    }
    if track:
        row["master_metadata_track_name"] = track[0]
        row["master_metadata_album_artist_name"] = track[1]
        row["master_metadata_album_album_name"] = track[2]
        row["spotify_track_uri"] = track[3]
    if episode:
        row["episode_name"] = episode[0]
        row["episode_show_name"] = episode[1]
        row["spotify_episode_uri"] = episode[2]
    return row


def play_length(rng, duration):
    r = rng.random()
    if r < 0.04:
        return rng.choice([0, 0, 1, 29_999, 30_000, 30_001])
    if r < 0.14:
        return rng.randint(1, 29_999)
    if r < 0.27:
        return rng.randint(30_000, duration)
    return max(0, duration + rng.randint(-400, 50))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--rows", type=int, default=50_000)
    ap.add_argument("--seed", type=int, default=20261117)
    ap.add_argument("--zip")
    ap.add_argument("--extended-only", action="store_true")
    args = ap.parse_args()
    rng = random.Random(args.seed)
    catalog = Catalog(rng, max(60, args.rows // 60))

    # Regular listening: sessions of back-to-back plays with gaps between, spread evenly.
    plays = []  # (end_ms, row)
    span = utc_ms(END) - utc_ms(START)
    sessions = max(1, args.rows // 10)
    # Gap between sessions, less the time a session and its random offset take on average.
    mean_gap = max(60_000, span / sessions - 3_800_000)
    cursor = utc_ms(START)
    while len(plays) < args.rows and cursor < utc_ms(END):
        cursor += int(rng.expovariate(1 / mean_gap)) + rng.randint(0, 3_600_000)
        for _ in range(rng.randint(1, 19)):
            if rng.random() < 0.05:
                ep = catalog.pick_episode()
                ms = play_length(rng, ep[3])
                row = extended_row(rng, cursor + ms, ms, episode=ep)
            else:
                tr = catalog.pick_track(cursor)
                ms = play_length(rng, tr[4])
                row = extended_row(rng, cursor + ms, ms, track=tr)
            end = cursor + ms
            plays.append((end, row))
            cursor = end + rng.randint(0, 4000)

    # Edge cases.
    def add(end_ms, ms, track=None, episode=None, **override):
        row = extended_row(rng, end_ms, ms, track, episode)
        row.update(override)
        plays.append((end_ms - end_ms % 1000, row))

    zones = ["Asia/Tashkent", "UTC", "America/New_York", "Europe/Berlin", "Pacific/Auckland",
             "Asia/Kolkata", "America/Santiago", "Pacific/Kiritimati"]
    for name in zones:
        z = ZoneInfo(name)
        for year in (2020, 2023, 2024, 2025):
            midnight = utc_ms(datetime(year, 1, 1, tzinfo=z))
            tr = catalog.pick_track()
            add(midnight - 30_000 + 180_000, 180_000, tr)        # starts 30 s before New Year, ends after
            add(midnight + 180_000, 180_000, catalog.pick_track())  # starts exactly at midnight
            add(midnight + 180_000, 180_001, catalog.pick_track())  # starts 1 ms before midnight
    for when in ["2024-03-10T07:00:00", "2024-11-03T06:00:00", "2024-03-31T01:00:00", "2024-10-27T01:00:00",
                 "2024-04-06T14:00:00", "2024-09-28T14:00:00", "2024-09-08T04:00:00", "2024-04-07T03:00:00"]:
        t = utc_ms(datetime.fromisoformat(when).replace(tzinfo=UTC))
        for delta in (-1_800_000, -1000, 0, 1000, 1_800_000):
            add(t + delta + 200_000, 200_000, catalog.pick_track())
    base = utc_ms(datetime(2024, 6, 15, 12, tzinfo=UTC))
    for i, ms in enumerate([0, 0, 1, 29_999, 30_000, 30_001]):
        add(base + i * 120_000 + 60_000, ms, catalog.pick_track())
    # The same title by different artists, all on one day.
    intros = [t for t in catalog.tracks if t[0] == "Intro"][:5]
    for i, tr in enumerate(intros):
        add(base + 3_600_000 + i * 300_000, 120_000, tr)
    # Null names with a URI (kept, shown as unknown), and rows with nothing to show.
    add(base + 7_200_000, 95_000, ("", "", "", "spotify:track:" + b62(rng), 95_000),
        master_metadata_track_name=None, master_metadata_album_artist_name=None,
        master_metadata_album_album_name=None)
    add(base + 7_400_000, 50_000, None, None)  # all null: skipped
    add(base + 7_600_000, 600_000, None, None, audiobook_title="Fixture Audiobook",
        audiobook_uri="spotify:audiobook:" + b62(rng), audiobook_chapter_title="Chapter 1")
    add(base + 7_800_000, 30_000, ("Ad", "Spotify", "", "spotify:ad:" + b62(rng, 16), 30_000))
    for i in range(30):
        ep = catalog.pick_episode()
        add(base + 86_400_000 * (i + 1), rng.randint(0, ep[3]), episode=ep)

    plays.sort(key=lambda p: p[0])
    rows = [r for _, r in plays]
    # About 1% exact duplicate rows, right after the original.
    with_dupes = []
    for r in rows:
        with_dupes.append(r)
        if rng.random() < 0.01:
            with_dupes.append(dict(r))
    rows = with_dupes

    ext_dir = os.path.join(args.out, "Spotify Extended Streaming History")
    acc_dir = os.path.join(args.out, "Spotify Account Data")
    os.makedirs(ext_dir, exist_ok=True)
    files = {}

    def year(r):
        return int(r["ts"][:4])

    video = [r for r in rows if r["spotify_episode_uri"] is not None and rng.random() < 0.3]
    video_ids = set(map(id, video))
    audio = [r for r in rows if id(r) not in video_ids]
    # Three audio files that overlap by 300 rows at each seam.
    n = len(audio)
    cuts = [0, n // 3, 2 * n // 3, n]
    for i in range(3):
        lo = max(0, cuts[i] - (300 if i else 0))
        part = audio[lo:cuts[i + 1]]
        if part:
            name = "Streaming_History_Audio_%d-%d_%d.json" % (year(part[0]), year(part[-1]), i)
            files[os.path.join(ext_dir, name)] = part
    if video:
        files[os.path.join(ext_dir, "Streaming_History_Video_%d-%d.json" % (year(video[0]), year(video[-1])))] = video
    # The older extended format name, with plays from 2018 nobody else has.
    old = []
    for i in range(40):
        tr = catalog.pick_track()
        end = utc_ms(datetime(2018, 6, 1, tzinfo=UTC)) + i * 600_000
        old.append(extended_row(rng, end, play_length(rng, tr[4]), track=tr))
    files[os.path.join(args.out, "MyData", "endsong_0.json")] = old

    if not args.extended_only:
        # Account data: the last year again, end time to the minute, fewer fields.
        last_ts = max(r["ts"] for r in rows)
        cutoff = (datetime.fromisoformat(last_ts.replace("Z", "+00:00")) - timedelta(days=365)).strftime(
            "%Y-%m-%dT%H:%M:%SZ")
        acc_music, acc_pod = [], []
        for r in rows:
            if r["ts"] < cutoff:
                continue
            end_ms = utc_ms(datetime.fromisoformat(r["ts"].replace("Z", "+00:00")))
            if (r["spotify_track_uri"] or "").startswith("spotify:ad:"):
                continue
            if r["master_metadata_track_name"]:
                acc_music.append({"endTime": end_time_string(end_ms), "artistName": r["master_metadata_album_artist_name"],
                                  "trackName": r["master_metadata_track_name"], "msPlayed": r["ms_played"]})
            elif r["episode_name"]:
                acc_pod.append({"endTime": end_time_string(end_ms), "podcastName": r["episode_show_name"],
                                "episodeName": r["episode_name"], "msPlayed": r["ms_played"]})
        # A few plays after the extended export was made: only in account data.
        t = utc_ms(datetime.fromisoformat(last_ts.replace("Z", "+00:00"))) + 3_600_000
        for _ in range(200):
            tr = catalog.pick_track()
            ms = play_length(rng, tr[4])
            t += ms + rng.randint(1000, 60_000)
            acc_music.append({"endTime": end_time_string(t), "artistName": tr[1], "trackName": tr[0], "msPlayed": ms})
        for i in range(0, len(acc_music), 10_000):
            files[os.path.join(acc_dir, "StreamingHistory_music_%d.json" % (i // 10_000))] = acc_music[i:i + 10_000]
        files[os.path.join(acc_dir, "StreamingHistory_podcast_0.json")] = acc_pod
        # Files that are not streaming history, which must be ignored.
        files[os.path.join(acc_dir, "Userdata.json")] = {"username": "fixture", "country": COUNTRY}
        files[os.path.join(acc_dir, "Playlist1.json")] = {"playlists": []}

    total = 0
    for path, data in files.items():
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2 if isinstance(data, dict) else None)
        if isinstance(data, list):
            total += len(data)
    print("wrote %d rows in %d files to %s" % (total, len(files), args.out))

    if args.zip:
        with zipfile.ZipFile(args.zip, "w", zipfile.ZIP_DEFLATED) as z:
            for path in sorted(files):
                z.write(path, os.path.relpath(path, args.out))
            # macOS junk that a zip made in Finder carries; must be ignored.
            z.writestr("__MACOSX/Spotify Account Data/._StreamingHistory_music_0.json", b"\x00\x05\x16\x07junk")
        print("zipped to %s" % args.zip)


if __name__ == "__main__":
    main()
