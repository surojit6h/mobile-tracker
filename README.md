# Mobile Tracker (small, battery-friendly, Android + iOS)

A tiny consent-based location tracker:

- **App** — a Flutter app (one codebase builds **Android APK + iOS**). It has a
  Start/Stop button and reports this phone's location to Supabase on a
  battery-friendly interval.
- **Supabase** — hosted Postgres database (no server to run). Stores one row per
  device and pushes live updates.
- **Dashboard** — a single web page (Leaflet + OpenStreetMap, no API key) that
  shows your devices on a live map.

```
Flutter app  ──►  Supabase (Postgres + Realtime)  ◄──  Web dashboard
```

> This is a tracker you run on **your own phones, with the person's knowledge**.
> The app is visible and has a Stop button. Don't use it to track anyone without
> their consent — that's illegal in most places.

---

## Folder layout

```
Mobile tracking system/
├─ app/            Flutter app (Android + iOS)
├─ dashboard/      Web dashboard (static files)
└─ supabase/       setup.sql — run once in Supabase
```

---

## Step 1 — Create the Supabase project (5 min)

1. Go to https://supabase.com, sign up (free), and create a **new project**.
   Pick a strong database password and a region near you.
2. Wait for it to finish provisioning.
3. Open **SQL Editor → New query**, paste the entire contents of
   `supabase/setup.sql`, and click **Run**. This creates the `devices` table,
   security policies, and turns on realtime.
4. Open **Project Settings → API** and copy these two values — you'll paste them
   into the app and the dashboard:
   - **Project URL** (looks like `https://abcd1234.supabase.co`)
   - **anon public** key (a long string)

The anon key is safe to put in client apps **because Row Level Security is on**.
See the security note at the bottom of `supabase/setup.sql` to harden it later.

---

## Step 2 — Run the dashboard

1. Edit `dashboard/config.js` and paste your two values:

   ```js
   window.APP_CONFIG = {
     SUPABASE_URL: "https://abcd1234.supabase.co",
     SUPABASE_ANON_KEY: "your-anon-public-key",
   };
   ```

2. Open the dashboard. The simplest local way:

   ```powershell
   # from the project root, using Python (any static server works)
   python -m http.server 8080 --directory dashboard
   ```

   Then visit http://localhost:8080. (Opening `index.html` directly as a file
   also works, but a server is cleaner.)

You should see the map. It stays empty until a phone reports in.

### Deploy the dashboard online (free)

The dashboard is just static files, so any static host works. Easiest options:

**Netlify (drag & drop)**
1. Go to https://app.netlify.com/drop
2. Drag the `dashboard` folder onto the page.
3. You get a public URL instantly. (Keep `config.js` filled in before uploading.)

**Vercel**
1. `npm i -g vercel`
2. From inside `dashboard/`, run `vercel` and follow the prompts.

**GitHub Pages**
1. Push `dashboard/` to a repo.
2. Repo **Settings → Pages → Deploy from branch**, pick the folder.

---

## Step 3 — Build the app

### Install Flutter (one time)

1. Install Flutter: https://docs.flutter.dev/get-started/install/windows
2. Confirm it works:

   ```powershell
   flutter --version
   flutter doctor
   ```

   Fix anything `flutter doctor` flags (Android SDK / Android Studio for the
   Android build).

### Generate the platform folders

This repo ships the app's `lib/`, `pubspec.yaml`, and the permission configs.
Generate the rest of the native project scaffolding once:

```powershell
cd "app"
flutter create .
```

`flutter create .` fills in the Android/iOS build files **without** overwriting
your `lib/` or `pubspec.yaml`.

### Add the location permissions

- **Android** — this repo already includes the permissions in
  `app/android/app/src/main/AndroidManifest.xml`. If `flutter create` replaced
  it, re-add the three `<uses-permission>` lines (INTERNET, ACCESS_FINE_LOCATION,
  ACCESS_COARSE_LOCATION).
- **iOS** — open `app/ios/Runner/Info.plist` and copy the two
  `NSLocation...UsageDescription` keys from
  `app/ios/Runner/Info-additions.plist` into it.

### Fill in your Supabase keys

Edit `app/lib/config.dart`:

```dart
static const String supabaseUrl = "https://abcd1234.supabase.co";
static const String supabaseAnonKey = "your-anon-public-key";
```

You can also tune battery usage here:
- `reportIntervalSeconds` — how often to upload (bigger = better battery).
- `minDistanceMeters` — ignore tiny movements.

### Get dependencies and run

```powershell
flutter pub get
flutter run        # with a phone/emulator connected, to test
```

---

## Step 4 — Build the installable Android APK

```powershell
cd "app"
flutter build apk --release
```

The APK lands at:

```
app/build/app/outputs/flutter-apk/app-release.apk
```

Copy that file to your Android phone and open it to install (you may need to
allow "install from unknown sources"). Open the app, name the device, press
**Start**, grant location permission, and it'll appear on your dashboard.

> To publish on the Google Play Store instead, build an app bundle
> (`flutter build appbundle`) and upload it in the Play Console
> (one-time $25 developer fee).

---

## Step 5 — Build the iOS app (needs a Mac)

Apple only allows iOS builds on macOS. You can't produce an iPhone build on
Windows — this is an Apple restriction, not a limitation of this project.

On a Mac with Xcode installed:

```bash
cd app
flutter build ios --release
```

Then open `app/ios/Runner.xcworkspace` in Xcode, sign it with your Apple ID, and
run it on your iPhone. To distribute to others you need an **Apple Developer
account ($99/year)** and TestFlight or the App Store.

The Dart code is identical for both platforms — only this build step needs a Mac.

---

## Battery notes

- Uses `LocationAccuracy.medium` + a distance filter, so GPS only wakes when the
  phone actually moves.
- Uploads on an interval (default every 2 minutes) rather than on every GPS tick.
- Increase `reportIntervalSeconds` / `minDistanceMeters` in `config.dart` for
  even longer battery life.

> Note: this version reports while the app is open/foregrounded. For
> always-on background tracking (phone in pocket, screen off) you'd add a
> background location service and request "Always" permission. I kept it
> foreground to stay small and avoid extra battery/permission complexity — ask
> if you want background tracking added.

---

## Troubleshooting

- **Dashboard says "Edit config.js"** — you haven't pasted your Supabase values.
- **Dashboard loads but no devices** — make sure a phone pressed Start and got
  location permission; check the Supabase **Table editor → devices** for rows.
- **App upload failed** — double-check `config.dart` URL/key and that you ran
  `supabase/setup.sql`.
- **`flutter` not recognized** — Flutter isn't installed or not on PATH. See
  Step 3.

---

## Cloud build — get the APK without installing Flutter

This repo includes a GitHub Actions workflow (`.github/workflows/build-apk.yml`)
that builds the release APK on GitHub's servers. You don't need Flutter or the
Android SDK on your PC.

The git repo is already initialized with a first commit. To build:

### 1. Create an empty repo on GitHub
- Go to https://github.com/new
- Name it e.g. `mobile-tracker`
- **Do not** add a README, .gitignore, or license (the repo already has them)
- Click **Create repository**

### 2. Push this project to it
Copy the repo URL GitHub shows you, then run (replace the URL):

```powershell
cd "D:\Mobile tracking system"
git remote add origin https://github.com/YOUR-USERNAME/mobile-tracker.git
git push -u origin main
```

GitHub will ask you to sign in (a browser window or a token prompt).

### 3. Watch the build
- On your repo page, open the **Actions** tab.
- The **Build Android APK** workflow starts automatically on push.
- Wait for the green check (first run ~5-10 min while it downloads Flutter).

### 4. Download the APK
- Click the finished workflow run.
- Under **Artifacts**, download **mobile-tracker-apk**.
- Unzip it to get `app-release.apk`.
- Copy that to your Android phone and install (allow "install from unknown
  sources" if asked).

### App icon
The app ships a custom launcher icon (a white location pin on a blue
background) at `app/assets/icon.png`. The CI build runs
`flutter_launcher_icons` automatically, so the installed APK shows this icon
instead of the default Flutter logo.

To change the icon: replace `app/assets/icon.png` with your own 1024x1024 PNG
(or edit `app/tool/make_icon.py` and run `python app/tool/make_icon.py`), then
push. The next build picks it up.

### Re-building later
Any time you change the app and run `git push`, a fresh APK builds
automatically. You can also trigger it manually: **Actions → Build Android APK →
Run workflow**.

> Note: your Supabase keys are committed in `app/lib/config.dart` and
> `dashboard/config.js`. The publishable key is safe to expose while RLS is on.
> If you'd rather keep the repo private, choose "Private" when creating it in
> step 1.
