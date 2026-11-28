# Pixie privacy policy

Last updated: November 27, 2026 (app version on server requests)

Pixie is a voice assistant for iPhone. This page explains what
the app does with your information. In short: your voice goes to OpenAI only while you're
in a call, your chat history stays on your iPhone, and the app has no ads, analytics or
tracking.

## Your voice during a call

When you start a call (the Start chat button, the Action Button, or saying "Hey Pixie"), the
app streams your microphone audio to OpenAI so Pixie can hear and answer you. Audio flows
directly between your iPhone and OpenAI and stops when the call ends. OpenAI processes it
under its [API data policies](https://openai.com/policies/api-data-usage-policies); calls
are set up with storage turned off.

To answer questions, Pixie may search the web. That search runs at OpenAI.

The app asks your permission before the first call. You can withdraw it any time in
Settings › Privacy ("Send voice to OpenAI in calls"); no call starts until you agree again.

## Your location

When you ask about something that depends on where you are (the weather, places near you,
directions from here) and don't name a place, Pixie may look up your iPhone's location once.
iOS asks your permission the first time, and only while you use the app. The area's name and
coordinates rounded to about 100 m go to OpenAI in that call so Pixie can answer. Pixie
doesn't track your location or keep it anywhere. You can turn it off in the iPhone's
Settings › Pixie › Location.

## Your calendar and reminders

When you ask about your schedule or reminders ("what's on tomorrow?", "remind me to call Mom
at 5"), Pixie reads or adds them in Apple's Calendar and Reminders on your iPhone, which
include any Google, Outlook or iCloud calendars you've added there. iOS asks for access the
first time. Only what a question needs (for example that day's events) is sent to OpenAI
during the call, and Pixie only adds, changes or deletes items when you ask. Nothing is sent
to the developer.

## Your contacts

When you ask Pixie to call someone ("call Sam"), it looks them up in your iPhone's contacts.
iOS asks your permission the first time. The names that match and their number labels
("mobile", "work") go to OpenAI in that call so Pixie can ask which one you mean; the phone
numbers themselves stay on your iPhone. Pixie only starts a call after you say yes, and iOS
asks you to confirm it too. You can turn this off in Settings › Pixie ("Find and call
contacts") or in the iPhone's Settings › Pixie › Contacts.

## Saved apps

You can save a page Pixie shows (a calculator, a checklist, this week's weather) as an app.
Saved apps, and anything you enter in them, stay on your iPhone; deleting an app deletes
its data too. A saved app can load from the web like any page Pixie shows.

Some apps show data that goes out of date, like the weather. When you open one after a
while, the app sends its page and the request it answers (for example "this week's weather
in Toronto") to OpenAI to remake it with fresh data. With your own key this goes straight to
OpenAI; with an invite code it goes through the Pixie server, which passes it on without
keeping it and counts the refreshes and the tokens they used.

## "Hey Pixie" listening

If you turn on background listening, the app listens for the phrase "Hey Pixie" using a
model that runs on your iPhone. Nothing you say leaves the phone until the phrase is heard
and a call starts. The app keeps a few seconds of recent audio in memory so the start of
your request isn't cut off, and discards it otherwise. You can turn listening off at any
time.

## Pixie's memory

Pixie can remember things about you between calls: things you ask it to remember, and
lasting facts it picks up in a call, such as people's names or where you live. Each is
saved as a short note on your iPhone, with the chat it came from. At the start of each call
the notes, with older ones merged into short summaries, are sent to OpenAI as part of the
call so Pixie knows them.

The summaries are written by OpenAI from those notes, usually overnight while your iPhone
charges, and only once there are enough notes to need them. With your own key this goes
straight to OpenAI; with an invite code it goes through the Pixie server, which passes the
notes on without keeping them. It counts the summaries and the tokens they used (see below).

You can see and delete notes in Settings › Memory. Deleting a chat also deletes what Pixie
remembered from it, unless you choose to keep it.

## Invite codes and the Pixie server

If you use an invite code instead of your own OpenAI key, each call is set up through a
small server (run on Cloudflare) that adds the app's OpenAI key. The server receives the
call's set-up request: your invite code, the call settings, and the network details needed
to connect. It does not receive your audio or what is said in the call. It keeps a count of
calls per invite per day, deleted after 3 days, to apply daily limits.

When a call with an invite code ends, the app sends the server how much it used: the voice
seconds OpenAI billed and the number of tokens Pixie's lookups used. Nothing else: no
transcript, audio, notes, call time or device details. The server adds these up per invite
per day (calls, voice seconds, tokens, memory summaries and saved-app refreshes with their tokens) to see what
Pixie costs to run, and deletes each day's totals after 90 days. Each request to the server also
says which version of the app sent it (for example "0.1.0 (202611280118)"); the server keeps the
latest one with that day's totals, so problems can be matched to a version. Cloudflare may keep
standard request logs under its own privacy policy.

If you use your own OpenAI key, calls go straight to OpenAI under your own account and the
Pixie server isn't involved. Your key is stored in your iPhone's Keychain.

## Sending feedback

If you ask Pixie to send feedback (for example "tell the developer the map was wrong"), the
app sends the Pixie server your feedback as Pixie heard it, Pixie's short note on what it was
about, the app's version, the name your invite code was made for, and any warnings the app was
showing at the time (for example "Weak call connection", "Low Power Mode on", or that a
permission is turned off), so problems can be traced. The developer reads
it to fix and improve Pixie. It is kept for a year and then deleted. Nothing is sent unless
you ask, and no audio or full transcript goes with it. Feedback is only sent from calls with
an invite code; with your own OpenAI key it stays on your iPhone. A copy is always kept on
your iPhone.

## What stays on your iPhone

- Chat history: the transcript of each call, and a record of the call's events, used to
  show and resume past chats. You can delete chats in the app.
- Pixie's memory: the notes and summaries described above.
- Settings, your invite code or key (in the Keychain), and anything you sign in to in the
  app's browser.
- Notes Pixie saves for you go to the folder you choose (for example an Obsidian vault).
- A copy of feedback you asked Pixie to send.
- Alarms and timers you ask Pixie to set: iOS keeps them, and Pixie keeps their labels.
- Apps you save, and what you enter in them.

None of this is sent to the developer, apart from feedback you ask Pixie to send.

## Other apps and websites

When you ask Pixie to play music, show a video, open a map or a website, the app opens a
link in Spotify, YouTube, Google Maps or its own browser. Those services handle what
happens there under their own policies. Pages and visuals shown in the app load from the
web.

## What the app doesn't do

- No ads, analytics or tracking, and no data sold or shared for advertising.
- No location tracking: your location is only looked up when a question needs it.
- No account with the developer.

## Children

Pixie isn't directed at children under 13.

## Reporting a response

Tap the flag under any of Pixie's replies to report it. This opens a report form on GitHub,
where reports are public; the reply is copied so you can choose whether to include it.

## Changes and contact

If this policy changes, this page will be updated with a new date. Questions: open an issue
at [github.com/kamikaz1k/wake-on](https://github.com/kamikaz1k/wake-on/issues).
