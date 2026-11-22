# Listening history

Tonearm keeps a record of what you play in Spotify. Liner Notes uses it to show your listening for a week, a month, a year or all time. The record stays on your Mac. There is no account and no login.

To open Liner Notes, click the chart button next to the gear in the player, or press ⌘L while the player is open. Settings → History → Open Liner Notes does the same.

The switch is in Settings → History → Record listening. It is on by default. The welcome window says so on a new install. If you had Tonearm before, the player says it once, the first time you open it after the update, with a button to turn it off.

## What is recorded

For each song or podcast episode you play while Tonearm is running:

- the title, artist and album (or episode and show)
- the Spotify ID, such as `spotify:track:4uLU6hMCjMI75M1A2tKUQC`
- its length and the cover image address Spotify reports
- when you started it, when you stopped, and how many milliseconds you actually listened

Tonearm counts only time the song was playing. Pauses, skipping ahead and sleep add nothing. Ads are never recorded.

A song you played for 30 seconds or more is a play, as Spotify counts streams. Settings and Liner Notes both count plays. Shorter plays and podcast episodes are kept too, as other entries: they add to your minutes, and podcasts get their own line.

Tonearm asks the Spotify app on your Mac what is playing, the same way it shows the player. It can't see Spotify on your phone or in a browser. To get those, import your Spotify data.

## What is never stored

- your Spotify account, password or email
- your IP address, country, device or platform. Spotify's export has these; the importer skips them, and the database has no place for them
- anything about other apps

## Where it is

`~/Library/Application Support/Tonearm/history.sqlite`, an SQLite database. Settings → History → Show in Finder opens the folder.

`Covers` in the same folder holds the covers the player downloaded for songs it recorded, so Liner Notes can show them without going online. Covers for imported plays aren't there: Spotify's export has none, so Liner Notes draws a tile instead.

Once you connect ListenBrainz, `listenbrainz.json` in the same folder holds the listens waiting to be sent. The ListenBrainz token is in your login Keychain, under "Tonearm ListenBrainz token".

## Import your Spotify history

A new install has no history. Spotify will send you all of it:

1. Go to [spotify.com/account/privacy](https://www.spotify.com/account/privacy/) and request your data. "Account data" covers the past year and takes a few days. "Extended streaming history" covers every year and takes up to 30 days. You can ask for both.
2. Spotify emails you a link to a .zip file.
3. In Tonearm, open Settings → History → Import Spotify data… and choose the .zip, the folder inside it, or the `StreamingHistory` and `Streaming_History` .json files.

You can import the same files twice, or both kinds of export. Tonearm keeps one copy of each play. When a play is in the export and Tonearm also recorded it, the export's copy wins: Spotify's own numbers are more exact.

The import reads the .zip on your Mac and keeps only the listening history. If Tonearm is stopped in the middle, nothing of that import is kept, and the unpacked copy of your download in the temporary folder is removed at the next import or launch.

### What Spotify's files look like

Spotify documents the fields on [Understanding my data](https://support.spotify.com/us/article/understanding-my-data/) and in the `ReadMeFirst_ExtendedStreamingHistory.pdf` inside the extended download. Neither says how the two kinds relate, so we checked real downloads that people published on GitHub with both kinds for the same months ([1](https://github.com/mungeraiden/quantified-self-project/tree/0a379031f6c83158ab4222940e8e251733d1cd2c/my_spotify_data), [2](https://github.com/egonik-unlp/my-spotify-data/tree/2b98dc7d48af2535d30ddb263c233a890d0b3f57), [3](https://github.com/HaniBou/Spotify-Habits/tree/03acdf2b3f92931d09bd57bb4a0236630f61dd2d/Data/Hani), [4](https://github.com/SigmaGrindset/spotify_stats/tree/4b5c7fa40d8663cef2b970494a9d103b94740cdf/api/public/data)), about 77,000 plays found in both:

- Both give the time the play ended, in UTC. Account data's `endTime` is the extended `ts` cut to the minute: a play that ended at 01:42:31 says "01:42", never "01:43". Of the 38,075 plays that ended 30 seconds or more into a minute, where cutting and rounding differ, all but 6 were cut, and those 6 were the same song replayed with the same length.
- `msPlayed` and `ms_played` are the same to the millisecond. So Tonearm matches a play across the two by its song, its artist, the minute it ended and the milliseconds played. The minute and the milliseconds alone pair 98.9 to 99.8% of account rows with an extended row in the months both cover; most of the rest are plays under 30 seconds.
- `master_metadata_album_artist_name` is, despite its name, the song's artist: it equals account data's `artistName` in over 99.9% of plays.
- About 0.3% of plays have a slightly different name in each kind, such as "Song (feat. Someone)" in one and "Song" in the other. If you import both kinds, those few plays in the months both cover count twice.
- `reason_end` says how a play ended. Since about 2016 it is almost always set (`trackdone` when the song played to its end). Rows from before 2015 may have `""`, and old `endsong` files have it empty for about a quarter of rows and `skipped` empty for nearly all. Tonearm treats an empty reason as unknown, which matters only for ListenBrainz (below).
- Old `endsong` files also have `ip_addr_decrypted`, `username` and `user_agent_decrypted`. The importer skips them like the rest.
- In the older account data file, `StreamingHistory0.json`, podcast episodes look like songs: the show is `artistName` and the episode `trackName`. Tonearm can't tell them apart there, so it counts them as music. Newer downloads put them in `StreamingHistory_podcast_0.json`.

The test fixture (`scripts/make-history-fixture.py`) and the importer's tests use these shapes.

## Export

Settings → History → Export saves every entry, plays and the rest, as CSV or JSON, oldest first, with these columns:

`started_at, ended_at, ms_played, kind, title, artist, album, spotify_uri, duration_ms, artwork_url, source, skipped, shuffle, offline, incognito, reason_start, reason_end`

Times are ISO 8601 in UTC. `source` is `live` for what Tonearm recorded and `import` for what came from Spotify's export.

In the CSV, text that starts with `=`, `+`, `-` or `@` gets a `'` in front, so Excel and Numbers show it instead of running it as a formula. The JSON is exactly as stored.

## Delete

Settings → History → Delete all history… asks first, with the number of plays and other entries, then deletes them all, and the kept covers. It also empties the ListenBrainz queue, since that holds song names. It also removes a share card waiting for the share menu and any unpacked Spotify download an interrupted import left behind. SQLite overwrites the deleted rows with zeros, then Tonearm rebuilds the database file and empties its write-ahead log, so no copy is left in Tonearm's files. It can't reach copies elsewhere, such as a Time Machine backup.

Turning off Record listening stops recording at once and keeps what is already there.

Deleting does not remove listens already sent to ListenBrainz. Delete those on listenbrainz.org.

## ListenBrainz

[ListenBrainz](https://listenbrainz.org) is an open, non-profit site that keeps your listening history in public, like Last.fm. Tonearm can send your listens there. It is off by default. Nothing leaves your Mac until you turn it on.

To turn it on:

1. Sign in at [listenbrainz.org](https://listenbrainz.org) and copy your user token from [your settings page](https://listenbrainz.org/settings/).
2. In Tonearm, open Settings → History, turn on Send to ListenBrainz, paste the token and click Connect.

Tonearm checks the token with ListenBrainz before it keeps it. It keeps the token in your Keychain, never in a settings file.

What it sends, following the [ListenBrainz API rules](https://listenbrainz.readthedocs.io/en/latest/users/api/core.html):

- When a song starts, "playing now": the title, artist, album, length and Spotify link.
- Once you have listened to half the song or 4 minutes, whichever is less, the listen itself, with the time it started. Each play is sent once.
- Podcasts are not sent.
- While Record listening is off, new plays are not recorded, so they are not sent either. Listens already waiting still go out.

If you are offline, or ListenBrainz is down, listens wait in `listenbrainz.json` and Tonearm tries again later: after 15 seconds, then 30, then 1 minute, doubling up to every 15 minutes. A listen leaves the queue only after ListenBrainz has accepted it, so quitting Tonearm or restarting the Mac loses nothing. Tonearm also follows the rate limit headers ListenBrainz sends and never makes more than one request a second.

If ListenBrainz stops accepting the token, Tonearm stops sending and asks for a new token. New plays still wait in the queue and go out once you paste a new one. Remove token deletes the old token and the queue.

**Send earlier listens.** Once connected, this sends what is stored but was not sent as you played: everything from before you connected, such as an imported Spotify export, and anything played while Send to ListenBrainz was off. It sends 1,000 listens per request, as ListenBrainz's "import" kind, and remembers where it got to, so it goes on after a quit or an error.

The same rule applies: half the song or 4 minutes, and never under 30 seconds. Spotify's export doesn't include song lengths, so Tonearm works them out:

- The extended streaming history says how each play ended. A play that ran to the end of the song gives its length. A play counts if it reached half of that. A song you never played to the end needs 4 minutes, so songs you always skipped are not sent.
- The account data download doesn't say how a play ended. For those, the longest time you ever played the song stands in for its length. A song you played once counts if you played it for 30 seconds or more.

**Remove token** deletes the token from the Keychain and forgets the queue. Listens already on ListenBrainz stay there.
