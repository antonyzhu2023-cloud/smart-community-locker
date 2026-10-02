# Smart Community Locker System (SCLS)

A mobile app for booking and opening **shared lockers in a community**, such as an
apartment building or a university campus. Unlike carrier-operated parcel lockers, SCLS is
not owned by one courier, lets a resident **book a compartment in advance**, and lets them
**pass one-time access to a neighbour** so an item can be handed over without the two people
meeting.

Built for COMP826 Mobile Systems Development, Auckland University of Technology.

> **Status:** Milestone 2 prototype. Not all requirements are fully implemented — see
> [Feature status](#feature-status).

---

## Screenshots

| Sign in | Locker map | Booking | Access code |
|---|---|---|---|
| _(add)_ | _(add)_ | _(add)_ | _(add)_ |

---

## How it works

```
Flutter app  ──HTTPS/TLS──▶  Firebase Cloud Functions  ──▶  Cloud Firestore
     ▲                                  │
     │ FCM push                         │ MQTT publish (QoS 1)
     │                                  ▼
     └──────────────────────  MQTT broker  ──▶  Locker controller
                                                (ESP32, or the Python simulator)
```

The app never decides whether an access code is valid. It asks the server for a signed,
single-use code with a 120-second lifetime, shows it as a QR code, and the **server**
validates the scanned payload before publishing an open command to the locker. The locker
reports the real door-sensor state back, and only then does the app tell the user the
compartment is open.

Architecture: **MVVM with a repository layer**. See [`docs/`](docs/) for the UML diagrams.

---

## Requirements

- Flutter 3.x and Dart 3.x — <https://docs.flutter.dev/get-started/install>
- Node.js 20+ (for the Cloud Functions)
- Python 3.10+ (for the locker simulator)
- A Firebase project with Authentication and Firestore enabled
- An MQTT broker — a free HiveMQ Cloud instance, or Mosquitto running locally
- Android Studio (for the Android SDK and emulator). Coding can be done in VS Code.

---

## Install and run

### 1. Clone

```bash
git clone https://github.com/antonyzhu2023-cloud/smart-community-locker.git
cd smart-community-locker
```

### 2. Configure Firebase

```bash
npm install -g firebase-tools
firebase login
cd app
flutterfire configure          # generates lib/firebase_options.dart
```

`firebase_options.dart` and `google-services.json` are gitignored. You must generate your
own — this repository contains no credentials.

### 3. Configure the MQTT broker

Copy the example config and fill in your broker details:

```bash
cp .env.example .env
```

```
MQTT_HOST=your-broker.hivemq.cloud
MQTT_PORT=8883
MQTT_USER=...
MQTT_PASS=...
```

### 4. Deploy the backend

```bash
cd functions
npm install
npm run build
firebase deploy --only functions,firestore:rules
```

To run locally instead of deploying:

```bash
firebase emulators:start
```

### 5. Start the locker simulator

The simulator takes the place of a physical cabinet. It subscribes to the open commands,
waits, and publishes a door-state event back.

```bash
cd simulator
pip install -r requirements.txt
python locker_sim.py --station STATION-01
```

### 6. Run the app

```bash
cd app
flutter pub get
flutter run
```

---

## Running the tests

```bash
cd app
flutter analyze
flutter test --coverage
```

CI enforces **70% line coverage on `lib/viewmodels/` and `lib/repositories/`**. The build
fails below that. See [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

---

## Feature status

Scope was cut once the submission date was known. Four features are built; the rest are
declared here rather than half-finished.

| ID | Feature | Status |
|---|---|---|
| FR1 | Register, verify membership, sign in | ⬜ in progress |
| FR2 | Nearby stations with free compartments | 🟡 seeded list, no map or GPS |
| FR3 | Book a compartment, cancel or extend | ⬜ in progress |
| FR4 | Signed single-use QR code, 120 s, PIN backup | ⬜ in progress |
| FR5 | Open the locker and report the real door state | ⬜ in progress |
| FR6 | Courier deposit and notify | ⬜ not implemented |
| FR7 | Hand over access to another user | ⬜ in progress |
| FR8 | Push notifications | ⬜ not implemented |
| FR9 | Usage history | ⬜ not implemented |

✅ done · 🟡 partial · ⬜ not implemented

---

## Repository layout

```
app/          Flutter application (MVVM)
  lib/views/         screens
  lib/viewmodels/    state and logic — unit tested
  lib/repositories/  data access behind interfaces
  lib/models/        domain entities
  lib/services/      LockerCommandGateway, location, notifications
functions/    Firebase Cloud Functions (TypeScript)
simulator/    Python MQTT locker simulator
docs/         UML diagrams and evaluation evidence
```

---

## Known limitations

- **Android only.** Building for iOS requires macOS, Xcode and a paid Apple developer
  account. The Flutter code base keeps the iOS target open, but it has not been built.
- **No physical cabinet.** A Python simulator plays the locker controller. The MQTT
  contract, the signing, the time-to-live and the idempotency handling are all real.
- Payment is calculated and displayed but not settled.

---

## Licence

Coursework. Not for production use.
