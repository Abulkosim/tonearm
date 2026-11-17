# Listening history

Tonearm keeps a record of what you play in Spotify. Liner Notes uses it to show your listening for a week, a month, a year or all time. The record stays on your Mac. There is no account and no login.

The switch is in Settings → History → Record listening. It is on by default.

## What is recorded

For each song or podcast episode you play while Tonearm is running:

- the title, artist and album (or episode and show)
- the Spotify ID, such as `spotify:track:4uLU6hMCjMI75M1A2tKUQC`
- its length and the cover image address Spotify reports
- when you started it, when you stopped, and how many milliseconds you actually listened

Tonearm counts only time the song was playing. Pauses, skipping ahead and sleep add nothing. Ads are never recorded.

Tonearm asks the Spotify app on your Mac what is playing, the same way it shows the player. It can't see Spotify on your phone or in a browser. To get those, import your Spotify data.

## What is never stored

- your Spotify account, password or email
- your IP address, country, device or platform. Spotify's export has these; the importer skips them, and the database has no place for them
- anything about other apps

## Where it is

`~/Library/Application Support/Tonearm/history.sqlite`, an SQLite database. Settings → History → Show in Finder opens the folder.

If ListenBrainz is on, `listenbrainz.json` in the same folder holds the listens waiting to be sent. The ListenBrainz token is in your login Keychain, under "Tonearm ListenBrainz token".

## Import your Spotify history

A new install has no history. Spotify will send you all of it:

1. Go to [spotify.com/account/privacy](https://www.spotify.com/account/privacy/) and request your data. "Account data" covers the past year and takes a few days. "Extended streaming history" covers every year and takes up to 30 days. You can ask for both.
2. Spotify emails you a link to a .zip file.
3. In Tonearm, open Settings → History → Import Spotify data… and choose the .zip, the folder inside it, or the `StreamingHistory` and `Streaming_History` .json files.

You can import the same files twice, or both kinds of export. Tonearm keeps one copy of each play. When a play is in the export and Tonearm also recorded it, the export's copy wins: Spotify's own numbers are more exact.

## Export

Settings → History → Export saves every listen as CSV or JSON, oldest first, with these columns:

`started_at, ended_at, ms_played, kind, title, artist, album, spotify_uri, duration_ms, artwork_url, source, skipped, shuffle, offline, incognito, reason_start, reason_end`

Times are ISO 8601 in UTC. `source` is `live` for what Tonearm recorded and `import` for what came from Spotify's export.

## Delete

Settings → History → Delete all history… asks first, with the number of listens, then deletes them all. It also empties the ListenBrainz queue, since that holds song names. Nothing deleted stays on disk: Tonearm overwrites the freed space and clears SQLite's write-ahead log.

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
- Nothing is sent while Record listening is off. ListenBrainz gets what Tonearm records, nothing more.

If you are offline, or ListenBrainz is down, listens wait in `listenbrainz.json` and Tonearm tries again later: after 15 seconds, then 30, then 1 minute, doubling up to every 15 minutes. A listen leaves the queue only after ListenBrainz has accepted it, so quitting Tonearm or restarting the Mac loses nothing. Tonearm also follows the rate limit headers ListenBrainz sends and never makes more than one request a second.

If ListenBrainz stops accepting the token, Tonearm stops sending, keeps the queue, and asks for a new token.

**Send earlier listens.** Once connected, this sends everything stored from before you connected, such as an imported Spotify export. It sends 1,000 listens per request, as ListenBrainz's "import" kind, and remembers where it got to, so it goes on after a quit or an error. Spotify's export doesn't include song lengths, so for these Tonearm uses the longest time you ever played the song as its length, and skips plays under 30 seconds.

**Remove token** deletes the token from the Keychain and forgets the queue. Listens already on ListenBrainz stay there.
