# Privacy

Mode has no server and no account of its own. Its authors receive nothing from
you: no tasks, screenshots, voice, usage data or crash reports. This is the same
on iPhone and Android.

## What stays on your phone

- Your tasks, chats, task history and the screenshots of each run.
- What Mode remembers (about you, people, places, how you like things done).
  See and delete it in Memory; Settings → Reset Mode deletes everything.
- Your name and settings.
- Timing and error records (local OpenTelemetry files, used for diagnosing slow
  or failed tasks). They never leave the phone unless you copy them yourself.
- Keys and sign-ins (OpenRouter key, ChatGPT and Claude sign-ins, voice keys):
  on iPhone in the Keychain, on Android in the Android Keystore, readable only
  by Mode on this device.
- A backup, if you make one, is a single file saved where you choose.

## What leaves your phone, and to whom

| When | What | Sent to |
|---|---|---|
| A task runs | Your task, screenshots of the screen and text read from it, earlier messages in that chat, and memory relevant to the task | The AI provider you chose: OpenAI (ChatGPT), Anthropic (Claude) or OpenRouter and the model maker you pick there |
| You talk to Mode with a cloud listener | Your recorded words | Deepgram or Soniox, if you chose one |
| Mode speaks with a cloud voice | Mode’s reply text | ElevenLabs, Fish Audio or Speechify, if you chose one |
| You talk to Mode on Android with the phone’s own listening | Your recorded words | Android’s speech recognizer (usually Google’s). It runs on the phone once its offline speech pack is installed; until then it may send your words to its maker |
| You connect a provider | Your key or sign-in | That provider only |

On iPhone, Apple’s voice and listening run on the phone. On Android, the
phone’s own voices run on the phone. Each provider handles your data under its
own privacy policy. Tasks marked private use and save no memory.

Mode looks at the screen only while a task runs. It is told never to type a
password, passcode or card number: when one is needed, it waits for you to
enter it.
Before memory is saved, Mode filters out things that look like keys, passwords
and card numbers.

## Android: phone control and background mode

- **Phone control** is an accessibility service you turn on once in Settings.
  Mode uses it to read the screen and tap only while a task runs; it does not
  watch or record what you do between tasks. Password fields are never read.
- **Reading the screen** uses what apps expose to accessibility. When a screen
  has no readable text (a game, a map), Mode reads the screenshot with Google’s
  on-device text recognition (ML Kit, through Google Play services). Either way
  the result goes only to your AI provider, as part of the task above.
- **Background mode** turns on Wireless debugging and pairs Mode with its own
  phone. The connection stays inside the phone (127.0.0.1), and Mode’s pairing
  key is kept in its own files. No computer is involved.

## Mode Setup (the computer app, iPhone only)

- Your Apple account password goes only to Apple.
- A sign-in helper (an “anisette” server run by the iLoader or SideStore
  open-source projects) tells Apple which computer you are signing in from. It
  never sees your password. You can switch helpers in Settings.
- Your Apple password is kept in the computer’s keychain only if you choose to.
- Mode Setup checks GitHub for new releases of Mode.
- The pairing file it makes for your iPhone stays on the iPhone and on that
  computer.

## The website (heymode.app)

The website counts how it's used, so we can tell what helps people get started.
This is about the website only: the Mode app (iPhone and Android) and Mode Setup
send nothing.

- What it counts: pages viewed, buttons clicked, how much of the film and the
  tour is watched, which sections are seen, and downloads (which installer and
  version).
- With each visit: a random ID saved in your browser (so a reload or a return
  visit counts as the same visitor), your country, the kind of device, system
  and browser, your language, your screen width, and the site that linked you.
- Not collected: your name, email, IP address or exact location. No cookies,
  no advertising, nothing shared with or sold to anyone.
- Where it's kept: in the website's own Cloudflare account, for up to three
  months.
- Turning it off: switch on "Do Not Track" or "Global Privacy Control" in your
  browser and nothing is counted. Clearing the site's data removes the saved ID.

## Questions

Open an issue at https://github.com/heymode/mode/issues.
