# Pixie privacy policy

Last updated: November 22, 2026

Pixie is an iPhone app for talking to Lobby, a voice assistant. This page explains what
the app does with your information. In short: your voice goes to OpenAI only while you're
in a call, your chat history stays on your iPhone, and the app has no ads, analytics or
tracking.

## Your voice during a call

When you start a call (the Start chat button, the Action Button, or saying "Hey Lobby"), the
app streams your microphone audio to OpenAI so Lobby can hear and answer you. Audio flows
directly between your iPhone and OpenAI and stops when the call ends. OpenAI processes it
under its [API data policies](https://openai.com/policies/api-data-usage-policies); calls
are set up with storage turned off.

To answer questions, Lobby may search the web. That search runs at OpenAI.

The app asks your permission before the first call. You can withdraw it any time in
Settings › Privacy ("Send voice to OpenAI in calls"); no call starts until you agree again.

## "Hey Lobby" listening

If you turn on background listening, the app listens for the phrase "Hey Lobby" using a
model that runs on your iPhone. Nothing you say leaves the phone until the phrase is heard
and a call starts. The app keeps a few seconds of recent audio in memory so the start of
your request isn't cut off, and discards it otherwise. You can turn listening off at any
time.

## Lobby's memory

Lobby can remember things about you between calls: things you ask it to remember, and
lasting facts it picks up in a call, such as people's names or where you live. Each is
saved as a short note on your iPhone, with the chat it came from. At the start of each call
the notes, with older ones merged into short summaries, are sent to OpenAI as part of the
call so Lobby knows them.

The summaries are written by OpenAI from those notes, usually overnight while your iPhone
charges, and only once there are enough notes to need them. With your own key this goes
straight to OpenAI; with an invite code it goes through the Lobby server, which passes the
notes on and keeps nothing but a count of summaries per invite per day, deleted after 3
days.

You can see and delete notes in Settings › Memory. Deleting a chat also deletes what Lobby
remembered from it, unless you choose to keep it.

## Invite codes and the Lobby server

If you use an invite code instead of your own OpenAI key, each call is set up through a
small server (run on Cloudflare) that adds the app's OpenAI key. The server receives the
call's set-up request: your invite code, the call settings, and the network details needed
to connect. It does not receive your audio or what is said in the call. It keeps a count of
calls per invite per day, deleted after 3 days, to apply daily limits. Cloudflare may keep
standard request logs under its own privacy policy.

If you use your own OpenAI key, calls go straight to OpenAI under your own account and the
Lobby server isn't involved. Your key is stored in your iPhone's Keychain.

## What stays on your iPhone

- Chat history: the transcript of each call, and a record of the call's events, used to
  show and resume past chats. You can delete chats in the app.
- Lobby's memory: the notes and summaries described above.
- Settings, your invite code or key (in the Keychain), and anything you sign in to in the
  app's browser.
- Notes Lobby saves for you go to the folder you choose (for example an Obsidian vault).

None of this is sent to the developer.

## Other apps and websites

When you ask Lobby to play music, show a video, open a map or a website, the app opens a
link in Spotify, YouTube, Google Maps or its own browser. Those services handle what
happens there under their own policies. Pages and visuals shown in the app load from the
web.

## What the app doesn't do

- No ads, analytics or tracking, and no data sold or shared for advertising.
- No location access.
- No account with the developer.

## Children

Pixie isn't directed at children under 13.

## Reporting a response

Tap the flag under any of Lobby's replies to report it. This opens a report form on GitHub,
where reports are public; the reply is copied so you can choose whether to include it.

## Changes and contact

If this policy changes, this page will be updated with a new date. Questions: open an issue
at [github.com/kamikaz1k/wake-on](https://github.com/kamikaz1k/wake-on/issues).
