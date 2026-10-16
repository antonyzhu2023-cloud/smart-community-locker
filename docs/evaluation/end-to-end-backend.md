# End-to-end check: the access path against the real server

The three files under `app/lib/repositories/firebase/` are excluded from the
coverage gate, because they do nothing but call Firebase and cannot run without
an emulator. This procedure is what covers them instead. Run it before
submission and record the result.

It also produces the evidence for evaluation criteria E4 and E5 against a real
server rather than a stand-in, which is the thing that was missing.

---

## Start the server

Two terminals, both at the repository root.

**Terminal 1.** Copy the secret file once, then start the emulators.

```bash
cp functions/.secret.local.example functions/.secret.local
cd functions && npm install && npm run build && cd ..
firebase emulators:start
```

Wait for the line listing the Auth, Firestore and Functions ports. The emulator
UI is at <http://localhost:4000> and is worth keeping open: the Firestore tab
shows the documents appearing as you go, which is the fastest way to see whether
the app reached the server at all.

No Firebase account is needed. The project id is `demo-scls`, and a project id
beginning `demo-` is one the emulators treat as never existing.

**Terminal 2.** Run the app against it.

```bash
cd app
flutter run --dart-define=BACKEND=functions
```

Without that flag the app runs on the in-memory stand-in, which is still the
default and still what the tests use.

---

## The checks

Work through these in order. Record pass or fail and what was seen.

| # | What to do | What should happen | Covers |
|---|---|---|---|
| 1 | Register with `WG-1041` | The locker list appears. In the emulator UI, `users/{id}` has a uid | FR1 |
| 2 | Register a second account with `WG-1042` in a fresh run | Second `users` document, different uid | FR1 |
| 3 | Book a compartment | A `reservations` document appears with `state: confirmed` and your uid | FR3 |
| 4 | Ask for an access code | A QR code and a countdown. An `accessTokens` document appears with `used: false` | FR4 |
| 5 | Watch the countdown reach zero, then present the code | Refused. The `accessLog` records the refusal | E4 |
| 6 | Get a new code and present it | Accepted, then the door reports open about three seconds later | FR5 |
| 7 | Present the same code again | Refused as already used. No second door event | E4, E5 |
| 8 | Cancel a booking, then ask for a code for it | Refused, because the booking is no longer openable | FR4 |
| 9 | Hand the booking to the second account | A second `accessTokens` document with `delegatedTo` set to the other uid | FR7 |
| 10 | Take the hand-over back before it is used | The document is gone, and the neighbour's shared booking disappears | FR7 |
| 11 | Open with the handed-over code, then take it back | Refused, with the message about it already being used | FR7 |
| 12 | Stop the emulators and ask for a code | The app says it could not reach the service, and does not crash | QR4 |

Check 12 matters more than it looks. The app is being asked to behave when the
thing that makes all the decisions is not there, and the honest answer is to say
so rather than to fall back on deciding locally.

---

## What this does and does not prove

It proves the access decision is made by a different process, which holds a key
the app has never seen. That is the claim evaluation criterion E4 rests on, and
until the app was wired to the functions it was a claim about an in-memory class
pretending to be a server.

It does not prove the deployment works, because there is no deployment. It does
not prove MQTT works, because the open command never leaves the machine: the
cabinet is simulated. And it is a manual procedure, which means it is only run
when somebody remembers to run it.

---

## Result

Run on: _(date)_

| # | Result | Note |
|---|---|---|
| 1 | | |
| 2 | | |
| 3 | | |
| 4 | | |
| 5 | | |
| 6 | | |
| 7 | | |
| 8 | | |
| 9 | | |
| 10 | | |
| 11 | | |
| 12 | | |
