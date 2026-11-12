# Tunnel

A personal "Strava for focus" iPhone app. Prop your phone up, start a session, and it:

- records a **timelapse** of you working (one frame every 1–5 s → a short 30 fps video)
- goes to a **black screen** at minimum brightness (OLED pixels off, so very little battery drain)
- uses the motion sensors to count every time you **pick the phone up**
- ends when you **hold the button for 2 seconds**
- builds a **Strava-style cover**, a transparent **sticker**, and a **share video** with a ticking clock, a progress bar and your stats burned in

## How it gets built without a Mac

Every push to `main` runs [.github/workflows/build.yml](.github/workflows/build.yml) on a free GitHub macOS runner.
It generates the Xcode project with XcodeGen, builds an unsigned app, and publishes `LockIn.ipa` as the
**latest** release.

## Installing on the iPhone (Windows, free Apple ID)

1. Download `LockIn.ipa` from the repo's **Releases → latest**.
2. Open **Sideloadly**, plug the iPhone in over USB, drag the `.ipa` in, enter your Apple ID, then press Start.
3. On the iPhone: **Settings → General → VPN & Device Management** → trust your Apple ID.
4. First time only: **Settings → Privacy & Security → Developer Mode** → on (the phone restarts).

Free Apple ID installs expire after 7 days. Re-run step 2 to refresh; your sessions stay on the phone.

## Tips

- Turn on **Guided Access** (Settings → Accessibility → Guided Access), then triple-click the side button
  during a session so you can't leave the app.
- Plug the phone in for long sessions.
- Your recordings are also visible in the Files app under **On My iPhone → Tunnel**.
