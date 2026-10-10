# Google Play Store Deployment Guide (via GitHub Actions)

This guide walks you through deploying your mobile tracking app to the **Google Play Store** directly from GitHub using your personal Google account (`surojit.sen6h@gmail.com`).

---

## 1. What Has Been Prepared In Your Codebase

1. **Package Name / Application ID**:
   Updated from the forbidden `com.example.*` to:
   ```text
   com.surojitsen.mobiletracker
   ```
2. **GitHub Actions Workflow (`.github/workflows/deploy-playstore.yml`)**:
   Automatically:
   * Sets up Java 17 and Flutter
   * Injects and signs with your release keystore
   * Builds the official **Android App Bundle (`.aab`)**
   * Uploads `.aab` and `.apk` to GitHub Actions Artifacts
   * Deploys directly to Google Play Store (Internal, Closed, or Production track) via the Google Play Developer API
3. **Automated Gradle Patch Script (`.github/scripts/configure-signing.py`)**:
   Injects secure release keystore credentials dynamically on the runner without exposing passwords in source code.

---

## 2. One-Time Setup Requirements

Google Play has strict one-time registration and signing rules before automated deployments are allowed:

### A. Google Play Console Account ($25 USD One-Time Fee)
1. Go to [Google Play Console](https://play.google.com/console).
2. Sign in with **`surojit.sen6h@gmail.com`**.
3. Choose **Developer Account** (Personal or Organization).
4. Pay Google's one-time **$25 USD registration fee**.
5. Complete account identity verification (ID upload).

---

### B. Generate Your App Signing Keystore

Open **PowerShell** on your computer and run this command:

```powershell
keytool -genkey -v -keystore upload-keystore.jks -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

* It will ask you for a password (e.g. choose a strong password like `MyTrackerPass2026!`).
* Answer the prompts (First/Last name: Surojit Sen, Organization, etc.).
* A file named `upload-keystore.jks` will be created.

> [!WARNING]
> **BACK UP `upload-keystore.jks` SAFELY!** If you lose this keystore file or forget its password, Google will not allow updates to your app.

Now convert your keystore into a Base64 string to store securely in GitHub:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("upload-keystore.jks")) | Set-Content "keystore_base64.txt"
```
Open `keystore_base64.txt` and copy the entire text.

---

### C. Add GitHub Repository Secrets

In your GitHub repository (`https://github.com/surojit6h/mobile-tracker`):
1. Click **Settings** > **Secrets and variables** > **Actions**.
2. Click **New repository secret** and add:

| Secret Name | Value | Description |
|---|---|---|
| `KEYSTORE_BASE64` | Content of `keystore_base64.txt` | Your encoded `.jks` file |
| `KEYSTORE_PASSWORD` | Password you chose during `keytool` | Keystore password |
| `KEY_ALIAS` | `upload` | Alias name from `keytool` |
| `KEY_PASSWORD` | Same password you chose | Key password |
| `PLAY_STORE_JSON_KEY` | *(Optional for first release, see Step E)* | Google Cloud Service Account JSON key |

---

### D. The Mandatory First-Time Manual Upload

> [!IMPORTANT]
> **Google's Rule:** The Google Play Developer API does **not** allow creating a brand-new app listing remotely. The **very first release** must be uploaded once manually through the Play Console web interface.

1. Go to GitHub > **Actions** tab > **Deploy to Google Play Store** > **Run workflow**.
2. When the build finishes, download the **`app-release-bundle`** artifact (contains `app-release.aab`).
3. In [Google Play Console](https://play.google.com/console):
   * Click **Create app**.
   * App name: **Mobile Tracker** (or your preferred brand name).
   * Default language: **English**.
   * App or game: **App** & Free or Paid: **Free**.
   * Go to **Testing** > **Internal testing** > **Create new release**.
   * Upload the `app-release.aab` file you downloaded.
   * Save and review the release.

Once this first manual upload is accepted by Google Play Console, the package `com.surojitsen.mobiletracker` is officially registered under your account!

---

### E. Enable Automated Deployments via Service Account

To let GitHub Actions upload future releases automatically:
1. In Google Play Console, go to **API access** (under Developer account settings).
2. Click **Link Google Cloud Project** (or create a new one).
3. Under **Service accounts**, click **Create service account**.
4. Follow the link to Google Cloud Console, create a service account named `github-deployer`.
5. Grant it role: **Service Account User**.
6. Under **Keys**, click **Add Key** > **Create new key** > **JSON**. Download the `.json` file.
7. Return to Google Play Console > **API access** > find the new service account > click **Manage Play Console permissions**.
8. Grant permissions:
   * View app information and download bulk reports
   * Create, edit, and delete draft apps
   * Release apps to testing tracks (and Production when ready)
9. Copy the entire contents of the downloaded `.json` file and paste it into GitHub Secret:
   * **`PLAY_STORE_JSON_KEY`**

---

## 3. How to Deploy from GitHub Actions

Once the one-time setup above is complete, you never need to build on your PC again!

### Option 1: Trigger Manually from GitHub (Recommended)
1. Go to your repo on GitHub: `https://github.com/surojit6h/mobile-tracker`.
2. Click the **Actions** tab.
3. Select **Deploy to Google Play Store** in the left sidebar.
4. Click **Run workflow**:
   * Select track: `internal` (or `alpha`, `beta`, `production`).
   * Select status: `completed`.
5. Click **Run workflow**. GitHub will build, sign, and upload to Google Play automatically!

### Option 2: Deploy by Pushing a Git Tag
To release a new version from command line:
1. Update `version: 1.0.1+2` in [`app/pubspec.yaml`](file:///d:/Mobile%20tracking%20system/app/pubspec.yaml).
2. Commit and tag:
   ```bash
   git tag v1.0.1
   git push origin v1.0.1
   ```
GitHub Actions will automatically trigger, build, and deploy the release to Google Play.
