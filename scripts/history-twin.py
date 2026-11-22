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
      Times an import of 100k listens, and the first all-time stats call on 200k in a new
      process with the OS file cache dropped. Fails over 10 s or 300 ms.

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
import re
import shutil
import sqlite3
import subprocess
import sys
import time
import zipfile
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


def run_tonearm(app, args, memory=False, env=None):
    """Runs Tonearm; returns stdout, stderr, seconds, and with `memory` the peak resident
    memory in bytes, from /usr/bin/time -l (macOS)."""
    started = time.monotonic()
    cmd = (["/usr/bin/time", "-l"] if memory else []) + [app] + args
    p = subprocess.run(cmd, capture_output=True, text=True, env=env)
    sys.stderr.write(p.stderr)
    if p.returncode != 0:
        sys.exit("tonearm exited %d" % p.returncode)
    elapsed = time.monotonic() - started
    if not memory:
        return p.stdout, p.stderr, elapsed
    peak = re.search(r"(\d+)\s+maximum resident set size", p.stderr)
    return p.stdout, p.stderr, elapsed, int(peak.group(1)) if peak else None


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

    # Privacy: values from ip_addr, ip_addr_decrypted, username and platform must be in neither the database nor the
    # exports. conn_country is a two-letter code, too short to grep for; the schema test
    # shows there is no column for it. Tonearm has exited and closed the database by now,
    # which empties the WAL, so the WAL is checked by a Swift test with the store open.
    run_tonearm(a.app, ["--stats", a.fixture, "--db", db, "--export", json_path])
    for path in (db, csv_path, json_path):
        with open(path, "rb") as f:
            blob = f.read()
        for needle in (b"192.0.2.", b"fixture-platform", b"fixture-user"):
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
    """Milliseconds from Tonearm's stderr lines that start with `prefix`."""
    return [int(re.search(r"(\d+) ms$", line).group(1)) for line in stderr.splitlines() if line.startswith(prefix)]


def phases(stderr, prefix):
    """The "phase NAME N ms" lines up to the first line starting with `prefix`: the parts of
    that call."""
    out = []
    for line in stderr.splitlines():
        if line.startswith("phase "):
            out.append(line[len("phase "):])
        elif line.startswith(prefix):
            break
    return ", ".join(out)


def purge():
    """Drops the OS file cache, as after a restart, if purge may run without a password (it
    can on CI runners). Returns whether it ran."""
    return subprocess.run(["sudo", "-n", "/usr/sbin/purge"], capture_output=True).returncode == 0


def require_purge():
    """purge(), but on CI a refused purge fails the check: the gated call would then read
    from the OS cache, and pass whatever the file looks like on disk."""
    if purge():
        return True
    if os.environ.get("CI"):
        sys.exit("purge was refused, so the first stats call would not be cold; the speed gate would test nothing")
    return False


def cold_first_calls(app, db, n):
    """The first all-time stats call in a new process after purge, n times."""
    out = []
    for _ in range(n):
        require_purge()
        _, err, _ = run_tonearm(app, ["--stats", "-", "--db", db, "--period", "all", "--tz", "Asia/Tashkent"])
        out.append(timing(err, "stats ")[0])
    return out


def median(xs):
    return sorted(xs)[len(xs) // 2]


def fresh(db):
    for suffix in ("", "-wal", "-shm"):
        if os.path.exists(db + suffix):
            os.remove(db + suffix)


# Limits. The first stats call in a new process, with the OS file cache dropped, is what
# someone sees opening Liner Notes right after a restart.
IMPORT_LIMIT_MS = 10_000      # 100k listens
FIRST_CALL_LIMIT_MS = 300     # all-time stats on 200k listens, cold


def cut_off_import(app, zip_path, zip_ms, work):
    """Kills Tonearm (SIGKILL, as a crash or a forced quit) in the middle of importing a zip,
    and checks that the database is whole and has none of the half-done import, then that
    the next import removes the unpacked export the killed one left behind."""
    tmp = os.path.join(work, "tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    env = dict(os.environ, TMPDIR=tmp + "/")
    db = os.path.join(work, "cut-off.sqlite")
    fresh(db)
    # A first import, so there is something to keep.
    small = os.path.join(work, "cut-off-first.json")
    with open(small, "w") as f:
        json.dump([{"endTime": "2024-03-05 10:00", "artistName": "A", "trackName": "T", "msPlayed": 60000}], f)
    run_tonearm(app, ["--stats", small, "--db", db])
    p = subprocess.Popen([app, "--stats", zip_path, "--db", db], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                         env=env)
    # Past the unzip, inside the import's transaction: about 60% of a whole run.
    time.sleep(zip_ms / 1000 * 0.6)
    running = p.poll() is None
    p.kill()
    p.wait()
    if not running:
        sys.exit("cut-off import: the import finished before it could be killed; nothing was tested")
    left = [n for n in os.listdir(tmp) if n.startswith("tonearm-import-")]
    if not left:
        # If Foundation did not take TMPDIR, the user's own temporary folder.
        user_tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
        if user_tmp and os.path.isdir(user_tmp):
            left = [n for n in os.listdir(user_tmp) if n.startswith("tonearm-import-")
                    and os.path.getmtime(os.path.join(user_tmp, n)) > time.time() - 120]
            if left:
                print("cut-off import: Tonearm unpacked into %s, not TMPDIR" % user_tmp)
                tmp = user_tmp
    con = sqlite3.connect(db)
    check = con.execute("PRAGMA integrity_check").fetchone()[0]
    count = con.execute("SELECT COUNT(*) FROM listens").fetchone()[0]
    con.close()
    problems = []
    if check != "ok":
        problems.append("integrity_check: %s" % check)
    if count != 1:
        problems.append("%d listens after the cut-off import, want the 1 from before it" % count)
    if not left:
        problems.append("no unpacked export left in %s, so the kill missed the import" % tmp)
    # The next import removes what is over an hour old.
    for n in left:
        old = time.time() - 2 * 3600
        os.utime(os.path.join(tmp, n), (old, old))
    run_tonearm(app, ["--stats", small, "--db", db], env=env)
    still = [n for n in os.listdir(tmp) if n.startswith("tonearm-import-")]
    if still:
        problems.append("the next import left %s in place" % still)
    fresh(db)
    shutil.rmtree(os.path.join(work, "tmp"), ignore_errors=True)
    if problems:
        sys.exit("cut-off import: " + "; ".join(problems))
    print("cut-off import: killed after %.1f s; database ok with only the earlier listen; the next import "
          "removed the %d unpacked export(s) left behind" % (zip_ms / 1000 * 0.6, len(left)))


def cmd_bench(a):
    os.makedirs(a.work, exist_ok=True)
    fixture = os.path.join(HERE, "make-history-fixture.py")
    results = {}
    # The generator stops at its end date, and drops duplicates and skips, so ask for
    # a quarter more rows than needed and check how many were stored.
    periods = ["--period", "all,all,all,year:2024", "--tz", "Asia/Tashkent", "--json", "--phases"]
    for target, ask in ((100_000, 125_000), (200_000, 250_000)):
        d = os.path.join(a.work, "bench-%d" % target)
        if not os.path.exists(d):
            subprocess.run([sys.executable, fixture, d, "--rows", str(ask), "--extended-only"], check=True)
        db = os.path.join(a.work, "bench-%d.sqlite" % target)
        fresh(db)
        _, err, _, peak = run_tonearm(a.app, ["--stats", d, "--db", db] + periods, memory=True)
        stored = int(re.search(r"(\d+) stored", err).group(1))
        if stored < target:
            sys.exit("only %d listens stored, wanted %d" % (stored, target))
        imp = timing(err, "import:")[0]
        after_import = timing(err, "stats ")[0]
        print("%d listens: import %d ms, peak memory %s MB (%s)"
              % (stored, imp, "%.0f" % (peak / 1e6) if peak else "?", phases(err, "import:")))
        # As after an app launch: a new process, SQLite's cache empty, the OS file cache
        # dropped.
        purged = require_purge()
        _, err, _ = run_tonearm(a.app, ["--stats", "-", "--db", db] + periods)
        st = timing(err, "stats ")
        print("  all-time stats in the importing process %d ms; in a new process%s %s ms (first call: %s); "
              "year 2024 %d ms" % (after_import, " after purge" if purged else " (purge not allowed)",
                                   ", ".join(map(str, st[:3])), phases(err, "stats "), st[3]))
        # The same new process, after what the app does at launch off the main thread
        # (HistoryStore.warmNow), as when someone opens Liner Notes a while after launch.
        purge()
        _, err, _ = run_tonearm(a.app, ["--stats", "-", "--db", db, "--warm"] + periods)
        warm_ms = timing(err, "warm:")[0]
        warmed = timing(err, "stats ")[0]
        print("  launch warm-up %d ms (%s), then first call %d ms" % (warm_ms, phases(err, "warm:"), warmed))
        # The gated number: one cold read is at the mercy of the runner's disk, so take the
        # median of three.
        cold = [st[0]] + cold_first_calls(a.app, db, 2) if target == 200_000 else [st[0]]
        results[target] = (imp, st, stored, warm_ms, warmed, peak, cold)

    # The same 200k import without the rewrite at the end, to show what it saves.
    d = os.path.join(a.work, "bench-200000")
    db = os.path.join(a.work, "bench-200000-uncompacted.sqlite")
    fresh(db)
    run_tonearm(a.app, ["--stats", d, "--db", db, "--no-compact", "--period", "year:2024"])
    require_purge()
    _, err, _ = run_tonearm(a.app, ["--stats", "-", "--db", db] + periods)
    st_nc = timing(err, "stats ")
    cold_nc = [st_nc[0]] + cold_first_calls(a.app, db, 2)
    print("200k without compacting: first call after purge %s ms, median %d (first: %s), then %s ms"
          % (", ".join(map(str, cold_nc)), median(cold_nc), phases(err, "stats "),
             ", ".join(map(str, st_nc[1:3]))))
    fresh(db)

    import_ms, _, n_import, _, _, peak, _ = results[100_000]
    _, st, n_stats, warm_ms, warmed, _, cold = results[200_000]

    # The import users run: the 100k folder as a zip, unpacked first. Measured, not gated.
    zip_path = os.path.join(a.work, "bench-100000.zip")
    if not os.path.exists(zip_path):
        d = os.path.join(a.work, "bench-100000")
        with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
            for root, _, names in os.walk(d):
                for name in sorted(names):
                    path = os.path.join(root, name)
                    z.write(path, os.path.relpath(path, d))
    _, err, _ = run_tonearm(a.app, ["--stats", zip_path, "--period", "year:2024"])
    zip_ms = timing(err, "import:")[0]
    print("zip of the 100k fixture: import %d ms, unzip included" % zip_ms)

    cut_off_import(a.app, zip_path, zip_ms, a.work)

    ok = import_ms < IMPORT_LIMIT_MS and median(cold) < FIRST_CALL_LIMIT_MS
    line = ("Liner Notes speed: import of %d listens %d ms (limit %d; %d ms from a zip, no limit; peak memory %s MB), "
            "all-time stats on %d listens: first call in a new process after purge, median %d ms of %s (limit %d; "
            "median %d ms without compacting), then %d ms; first call after the launch warm-up %d ms (warm-up %d ms, "
            "no limit)"
            % (n_import, import_ms, IMPORT_LIMIT_MS, zip_ms, "%.0f" % (peak / 1e6) if peak else "?", n_stats,
               median(cold), ", ".join(map(str, cold)), FIRST_CALL_LIMIT_MS, median(cold_nc), min(st[1:3]), warmed,
               warm_ms))
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
