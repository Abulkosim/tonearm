#!/usr/bin/env python3
"""The slow twin of Tonearm's Liner Notes: the same stats, computed independently in plain
Python straight from the raw Spotify export JSON. CI runs both on a fixture and fails on
any difference.

  history-twin.py stats EXPORT_DIR [--period all] [--tz Asia/Tashkent]
      Prints the stats as JSON, in the shape `Tonearm --stats ... --json` prints.
  history-twin.py check --app TONEARM_BINARY --fixture EXPORT_DIR --zip EXPORT_ZIP --work DIR
      Runs Tonearm on the zip and then the folder (so it also imports everything twice),
      compares every period and time zone below, and checks that no ip_addr, conn_country
      or platform value reached the database or an export.
  history-twin.py bench --app TONEARM_BINARY --work DIR
      Times an import of 100k rows and all-time stats on 200k rows.

The rules (Sources/Tonearm/History/StatsEngine.swift and HistoryImport.swift follow them):
  Files: names starting with StreamingHistory, Streaming_History_ or endsong, ending .json,
    not inside __MACOSX, not starting with "._". Read in path order.
  Rows: "ts" means extended history (end time to the second), "endTime" account data (end
    time to the minute). Extended: a song if it has a track URI or name, else an episode if
    it has an episode URI or name, else skipped; ad URIs are skipped. Account data: an
    episode if the row has podcastName or episodeName, else a song; skipped if it has
    neither a title nor an artist. start = end - ms_played.
  Duplicates: same (kind, artist, title, URI if no title, end minute, ms_played). The row
    with the finer end time wins, then the earlier end, then the first one read.
  Stats: see `Stats` in HistoryTypes.swift.
"""
import argparse
import calendar
import json
import os
import subprocess
import sys
import time
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

THRESHOLD = 30_000
TOP = 10
TOP_SHOWS = 5
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
HERE = os.path.dirname(os.path.abspath(__file__))

ZONES = ["Asia/Tashkent", "UTC", "America/New_York", "Europe/Berlin", "Pacific/Auckland",
         "Asia/Kolkata", "America/Santiago", "Pacific/Kiritimati"]
PERIODS = (["all"] + ["year:%d" % y for y in range(2018, 2027)]
           + ["month:2019-01", "month:2024-03", "month:2024-06", "month:2024-10", "month:2024-11",
              "month:2024-12", "month:2025-01", "month:2025-11"]
           + ["week:2024-03-10", "week:2024-04-06", "week:2024-06-15", "week:2024-09-28",
              "week:2024-10-27", "week:2024-11-03", "week:2024-12-30", "week:2023-12-31",
              "week:2025-11-26"])


# ---- reading ----

def history_files(root):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != "__MACOSX"]
        for name in filenames:
            n = name.lower()
            if not n.endswith(".json") or n.startswith("._"):
                continue
            if n.startswith("streaminghistory") or n.startswith("streaming_history_") or n.startswith("endsong"):
                found.append(os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/"))
    return [os.path.join(root, rel) for rel in sorted(found)]


def text(v):
    return v if isinstance(v, str) else ""


def millis(v):
    if isinstance(v, bool):
        v = int(v)
    if isinstance(v, (int, float)):
        return int(v) if v > 0 else 0
    if isinstance(v, str):
        try:
            f = float(v)
        except ValueError:
            return 0
        return int(f) if f > 0 and f != float("inf") else 0
    return 0


def to_ms(dt):
    return calendar.timegm(dt.utctimetuple()) * 1000 + dt.microsecond // 1000


def parse_ts(s):
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return to_ms(dt)


def parse_end_time(s):
    try:
        return to_ms(datetime.strptime(s, "%Y-%m-%d %H:%M").replace(tzinfo=timezone.utc))
    except ValueError:
        return None


def parse_row(row):
    """(kind, title, artist, album, uri, end_ms, ms, precision) or None."""
    if not isinstance(row, dict):
        return None
    if isinstance(row.get("ts"), str):
        end = parse_ts(row["ts"])
        if end is None:
            return None
        ms = millis(row.get("ms_played"))
        t_uri, t_name = text(row.get("spotify_track_uri")), text(row.get("master_metadata_track_name"))
        e_uri, e_name = text(row.get("spotify_episode_uri")), text(row.get("episode_name"))
        if t_uri or t_name:
            r = (0, t_name, text(row.get("master_metadata_album_artist_name")),
                 text(row.get("master_metadata_album_album_name")), t_uri, end, ms, 1)
        elif e_uri or e_name:
            r = (1, e_name, text(row.get("episode_show_name")), "", e_uri, end, ms, 1)
        else:
            return None
        if r[4].startswith("spotify:ad:"):
            return None
        return r
    if isinstance(row.get("endTime"), str):
        end = parse_end_time(row["endTime"])
        if end is None:
            return None
        ms = millis(row.get("msPlayed"))
        if "podcastName" in row or "episodeName" in row:
            r = (1, text(row.get("episodeName")), text(row.get("podcastName")), "", "", end, ms, 0)
        else:
            r = (0, text(row.get("trackName")), text(row.get("artistName")), "", "", end, ms, 0)
        if not r[1] and not r[2]:
            return None
        return r
    return None


def load(root):
    """Unique listens and import counts."""
    best = {}
    order = []
    counts = {"files": 0, "rows": 0, "skipped": 0}
    for path in history_files(root):
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (ValueError, UnicodeDecodeError):
            continue
        if not isinstance(data, list):
            continue
        counts["files"] += 1
        counts["rows"] += len(data)
        for row in data:
            r = parse_row(row)
            if r is None:
                counts["skipped"] += 1
                continue
            kind, title, artist, album, uri, end, ms, precision = r
            key = (kind, artist, title, uri if not title else None, end // 60_000, ms)
            old = best.get(key)
            if old is None:
                best[key] = r
                order.append(key)
            elif precision > old[7] or (precision == old[7] and end < old[5]):
                best[key] = r
    listens = [best[k] for k in order]
    counts["added"] = len(listens)
    return listens, counts


# ---- stats ----

def local_parts(ms, zone):
    dt = (EPOCH + timedelta(milliseconds=ms)).astimezone(zone)
    return dt.date(), dt.hour


def period_range(p):
    if p == "all":
        return None
    kind, value = p.split(":", 1)
    if kind == "year":
        y = int(value)
        return date(y, 1, 1), date(y + 1, 1, 1)
    if kind == "month":
        y, m = map(int, value.split("-"))
        return date(y, m, 1), (date(y + 1, 1, 1) if m == 12 else date(y, m + 1, 1))
    if kind == "week":
        d = date.fromisoformat(value)
        monday = d - timedelta(days=d.weekday())
        return monday, monday + timedelta(days=7)
    raise ValueError(p)


def period_name(p):
    r = period_range(p)
    if r and p.startswith("week:"):
        return "week:" + r[0].isoformat()
    return p


def ranked(groups, limit, with_artist):
    """groups: key -> [ms, listens]; key is a name or (title, artist)."""
    items = []
    for key, (ms, n) in groups.items():
        if ms <= 0:
            continue
        name, artist = (key if with_artist else (key, None))
        items.append((-ms, -n, name, artist or "", name, artist, ms, n))
    items.sort(key=lambda t: t[:4])
    out = []
    for t in items[:limit]:
        item = {"name": t[4], "ms": t[6], "listens": t[7]}
        if with_artist:
            item["artist"] = t[5]
        out.append(item)
    return out


_located = {}


def locate(listens, zone_name):
    """Each listen with its local start day and hour, and each artist's first day with a
    play of 30 s or more. Cached per time zone."""
    key = (id(listens), zone_name)
    if key not in _located:
        zone = ZoneInfo(zone_name)
        located = [(local_parts(l[5] - l[6], zone), l) for l in listens]
        first_heard = {}
        for (day, _), l in located:
            if l[0] == 0 and l[6] >= THRESHOLD and l[2]:
                if l[2] not in first_heard or day < first_heard[l[2]]:
                    first_heard[l[2]] = day
        _located[key] = (located, first_heard)
    return _located[key]


def stats(listens, zone_name, p):
    rng = period_range(p)
    located, first_heard = locate(listens, zone_name)

    def inside(day):
        return rng is None or rng[0] <= day < rng[1]

    music = {"ms": 0, "listens": 0}
    pod = {"ms": 0, "listens": 0}
    artists, tracks, albums, shows = {}, {}, {}, {}
    u_artists, u_tracks, u_albums, u_shows = set(), set(), set(), set()
    daily = {}
    heat = [[0] * 24 for _ in range(7)]
    listen_days = set()
    for (day, hour), l in located:
        if not inside(day):
            continue
        kind, title, artist, album, _, _, ms, _ = l
        counted = ms >= THRESHOLD
        if kind == 1:
            pod["ms"] += ms
            pod["listens"] += counted
            if artist:
                g = shows.setdefault(artist, [0, 0])
                g[0] += ms
                g[1] += counted
                if counted:
                    u_shows.add(artist)
            continue
        music["ms"] += ms
        music["listens"] += counted
        daily[day] = daily.get(day, 0) + ms
        heat[day.weekday()][hour] += ms
        if counted:
            listen_days.add(day)
        if artist:
            g = artists.setdefault(artist, [0, 0])
            g[0] += ms
            g[1] += counted
            if counted:
                u_artists.add(artist)
        if title:
            g = tracks.setdefault((title, artist), [0, 0])
            g[0] += ms
            g[1] += counted
            if counted:
                u_tracks.add((title, artist))
        if album:
            g = albums.setdefault((album, artist), [0, 0])
            g[0] += ms
            g[1] += counted
            if counted:
                u_albums.add((album, artist))

    new = {a: g for a, g in artists.items() if a in first_heard and inside(first_heard[a])}

    if rng:
        days = [rng[0] + timedelta(days=i) for i in range((rng[1] - rng[0]).days)]
    elif daily:
        lo, hi = min(daily), max(daily)
        days = [lo + timedelta(days=i) for i in range((hi - lo).days + 1)]
    else:
        days = []

    busiest = None
    for day in sorted(daily):
        if daily[day] > 0 and (busiest is None or daily[day] > busiest[1]):
            busiest = (day, daily[day])

    streak = None
    for day in sorted(listen_days):
        if day - timedelta(days=1) in listen_days:
            continue
        end = day
        while end + timedelta(days=1) in listen_days:
            end += timedelta(days=1)
        n = (end - day).days + 1
        if streak is None or n > streak[0]:
            streak = (n, day, end)

    m = {
        "ms": music["ms"],
        "listens": music["listens"],
        "uniqueTracks": len(u_tracks),
        "uniqueArtists": len(u_artists),
        "uniqueAlbums": len(u_albums),
        "topArtists": ranked(artists, TOP, False),
        "topTracks": ranked(tracks, TOP, True),
        "topAlbums": ranked(albums, TOP, True),
        "daily": [{"day": d.isoformat(), "ms": daily.get(d, 0)} for d in days],
        "heatmap": heat,
        "newArtists": {"count": len(new), "top": ranked(new, TOP, False)},
    }
    if streak:
        m["longestStreak"] = {"days": streak[0], "start": streak[1].isoformat(), "end": streak[2].isoformat()}
    if busiest:
        m["busiestDay"] = {"day": busiest[0].isoformat(), "ms": busiest[1]}
    out = {
        "period": period_name(p),
        "music": m,
        "podcasts": {"ms": pod["ms"], "listens": pod["listens"], "shows": len(u_shows),
                     "topShows": ranked(shows, TOP_SHOWS, False)},
    }
    if rng:
        out["start"], out["end"] = rng[0].isoformat(), rng[1].isoformat()
    return out


# ---- commands ----

def diff(a, b, path="", out=None):
    out = [] if out is None else out
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                out.append("%s/%s: only in %s" % (path, k, "tonearm" if k in a else "twin"))
            else:
                diff(a[k], b[k], "%s/%s" % (path, k), out)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append("%s: %d items in tonearm, %d in twin" % (path, len(a), len(b)))
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, "%s[%d]" % (path, i), out)
    elif a != b:
        out.append("%s: tonearm %r, twin %r" % (path, a, b))
    return out


def run_tonearm(app, args):
    started = time.monotonic()
    p = subprocess.run([app] + args, capture_output=True, text=True)
    sys.stderr.write(p.stderr)
    if p.returncode != 0:
        sys.exit("tonearm exited %d" % p.returncode)
    return p.stdout, p.stderr, time.monotonic() - started


def cmd_stats(a):
    listens, _ = load(a.export)
    print(json.dumps(stats(listens, a.tz, a.period), ensure_ascii=False, indent=2, sort_keys=True))


def cmd_check(a):
    os.makedirs(a.work, exist_ok=True)
    db = os.path.join(a.work, "check.sqlite")
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(db + suffix):
            os.remove(db + suffix)
    csv_path = os.path.join(a.work, "export.csv")
    json_path = os.path.join(a.work, "export.json")
    # Why Tonearm falls back to unzip: what plain ditto says about this zip.
    plain = subprocess.run(["/usr/bin/ditto", "-x", "-k", a.zip, os.path.join(a.work, "plain-ditto")],
                           capture_output=True, text=True)
    print("plain ditto: exit %d %s" % (plain.returncode, plain.stderr.strip()[:300]))
    out, _, secs = run_tonearm(a.app, ["--stats", a.zip, "--stats", a.fixture, "--period", ",".join(PERIODS),
                                       "--tz", ",".join(ZONES), "--json", "--db", db, "--export", csv_path])
    swift = json.loads(out)
    print("tonearm: %d stats in %.1f s" % (len(swift["stats"]), secs))

    started = time.monotonic()
    listens, counts = load(a.fixture)
    problems = []
    imp = swift["import"]
    # The same export twice: every row is read twice, and only the first copy is added.
    expect = {"files": 2 * counts["files"], "rows": 2 * counts["rows"], "skipped": 2 * counts["skipped"],
              "added": counts["added"], "duplicates": 2 * counts["rows"] - 2 * counts["skipped"] - counts["added"],
              "replacedLive": 0}
    for k, v in expect.items():
        if imp.get(k) != v:
            problems.append("import/%s: tonearm %r, twin %r" % (k, imp.get(k), v))
    if imp.get("unreadable"):
        problems.append("import/unreadable: %r" % imp["unreadable"])

    compared = 0
    for zone in ZONES:
        for p in PERIODS:
            key = "%s %s" % (zone, period_name(p))
            mine = stats(listens, zone, p)
            theirs = swift["stats"].get(key)
            if theirs is None:
                problems.append("%s: missing from tonearm" % key)
                continue
            problems += ["%s %s" % (key, d) for d in diff(theirs, mine)]
            compared += 1
    print("twin: %d listens, %d stats in %.1f s" % (len(listens), compared, time.monotonic() - started))

    # Privacy: values from ip_addr, conn_country and platform must be nowhere.
    run_tonearm(a.app, ["--stats", a.fixture, "--db", db, "--export", json_path])
    for path in (db, db + "-wal", csv_path, json_path):
        if not os.path.exists(path):
            continue
        with open(path, "rb") as f:
            blob = f.read()
        for needle in (b"192.0.2.", b"fixture-platform", b'"ZZ"', b",ZZ,"):
            if needle in blob:
                problems.append("privacy: %r found in %s" % (needle, os.path.basename(path)))
    with open(csv_path, encoding="utf-8") as f:
        exported = sum(1 for _ in f) - 1
    if exported != counts["added"]:
        problems.append("export: %d rows in CSV, %d listens" % (exported, counts["added"]))

    music_ms = sum(l[6] for l in listens if l[0] == 0)
    print("fixture: %d files, %d rows, %d skipped, %d unique listens, %.0f h of music"
          % (counts["files"], counts["rows"], counts["skipped"], counts["added"], music_ms / 3.6e6))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if problems:
        print("\n%d differences:" % len(problems))
        for line in problems[:60]:
            print("  " + line)
        if summary:
            with open(summary, "a") as f:
                f.write("Liner Notes twin: %d differences\n" % len(problems))
        sys.exit(1)
    print("twin check passed: %d period and time zone pairs agree, import counts agree, no private fields stored"
          % compared)
    if summary:
        with open(summary, "a") as f:
            f.write("Liner Notes twin: %d stats agree on %d listens\n" % (compared, counts["added"]))


def timing(stderr, prefix):
    out = []
    for line in stderr.splitlines():
        if line.startswith(prefix):
            out.append(int(line.rsplit(",", 1)[-1].split()[-2] if prefix == "import:" else line.split()[-2]))
    return out


def cmd_bench(a):
    os.makedirs(a.work, exist_ok=True)
    fixture = os.path.join(HERE, "make-history-fixture.py")
    results = {}
    for rows in (100_000, 200_000):
        d = os.path.join(a.work, "bench-%d" % rows)
        if not os.path.exists(d):
            subprocess.run([sys.executable, fixture, d, "--rows", str(rows), "--extended-only"], check=True)
        _, err, _ = run_tonearm(a.app, ["--stats", d, "--period", "all,all,all,year:2024", "--tz", "Asia/Tashkent",
                                        "--json"])
        imp = timing(err, "import:")
        st = timing(err, "stats ")
        results[rows] = (imp[0], st)
        print("%d rows: import %d ms; all-time stats %s ms (first is cold); year 2024 %d ms"
              % (rows, imp[0], ", ".join(map(str, st[:3])), st[3]))
    import_ms = results[100_000][0]
    stats_ms = min(results[200_000][1][:3])
    ok = import_ms < 5000 and stats_ms < 300
    line = ("Liner Notes speed: import of 100k rows %d ms (limit 5000), all-time stats on 200k rows %d ms warm, "
            "%d ms cold (limit 300)" % (import_ms, stats_ms, results[200_000][1][0]))
    print(line)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(line + "\n")
    if not ok:
        sys.exit("too slow")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("stats")
    s.add_argument("export")
    s.add_argument("--period", default="all")
    s.add_argument("--tz", default="UTC")
    c = sub.add_parser("check")
    c.add_argument("--app", required=True)
    c.add_argument("--fixture", required=True)
    c.add_argument("--zip", required=True)
    c.add_argument("--work", required=True)
    b = sub.add_parser("bench")
    b.add_argument("--app", required=True)
    b.add_argument("--work", required=True)
    a = ap.parse_args()
    {"stats": cmd_stats, "check": cmd_check, "bench": cmd_bench}[a.cmd](a)


if __name__ == "__main__":
    main()
