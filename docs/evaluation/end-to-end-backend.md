# End-to-end check: the access path against the real server

The three files under `app/lib/repositories/firebase/` are excluded from the
coverage gate, because they do nothing but call Firebase and cannot run without
an emulator. This procedure is what covers them instead. Run it before
submission and record the result.

It also produces the evidence for evaluation criteria E4 and E5 against a real
server rather than a stand-in, which is the thing that was missing.

---

## Start the server

### "Emulator" means two different things here

The word appears twice in this procedure and refers to two unrelated programs.
Mixing them up is the most likely way to lose half an hour.

| Name | What it is | Started by |
|---|---|---|
| **Android emulator** | A virtual phone. The app runs inside it. | `flutter emulators --launch <name>` |
| **Firebase Local Emulator Suite** | Fake Auth, Firestore and Cloud Functions running on the development machine. The app talks to it over the network. | `firebase emulators:start` |

Three things have to be running: the virtual phone, the fake server, and the
app. In that order.

### Once only: the signing secret and the functions build

```powershell
cd C:\dev\smart-community-locker
copy functions\.secret.local.example functions\.secret.local
cd functions
npm install
npm run build
cd ..
```

Commands are on separate lines on purpose. Windows PowerShell 5.1 does not
support `&&` between commands.

### Terminal 1: the virtual phone

```powershell
flutter emulators
flutter emulators --launch Pixel_7
```

The first command lists the emulators that exist on this machine. Use whatever
name it prints; `Pixel_7` is only an example. Wait for the phone to finish
booting to its home screen before going on.

### Terminal 2: the fake server

```powershell
cd C:\dev\smart-community-locker
firebase emulators:start
```

Wait for the table listing the Auth, Firestore and Functions ports. Leave this
terminal running; closing it is how check 12 is performed.

Open <http://localhost:4000> in a browser and go to the Firestore tab. Documents
appear there as the app is used, which is the fastest way to see whether the app
reached the server at all. Keep it on screen.

No Firebase account is needed. The project id is `demo-scls`, and the emulators
treat a project id beginning `demo-` as one that does not exist.

### Terminal 3: the app

```powershell
cd C:\dev\smart-community-locker\app
flutter run --dart-define=BACKEND=functions
```

**The flag is not optional.** Without it the app runs on the in-memory
stand-in, every check below will appear to pass, and none of them will have
tested the server. If the Firestore tab stays empty while you use the app, the
flag was missing.

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

Run on **24 October 2026**, against the Cloud Functions in the Firebase Local Emulator
Suite, with the app on a Chrome build. The Android emulator was abandoned after repeated
failures to start, which cost most of a day and is recorded in `DEVLOG.md`. The client
platform does not affect this procedure: every piece of evidence below is a server-side
record, and the server receives the same calls either way.

| # | Result | What was seen |
|---|---|---|
| 1 | Pass | `users` document created with a uid |
| 2 | Pass | Second account, different uid |
| 3 | Pass | `reservations` document with `state: confirmed` and the owner's uid |
| 4 | Pass | `accessTokens` document, `used: false`, expiry 120 s ahead |
| 5 | **Not reachable** | The screen removes the open button the moment the code expires |
| 6 | Pass | Accepted, door reported open about three seconds later |
| 7 | **Not reachable** | The screen clears the code after a successful open |
| 8 | **Not reachable** | A cancelled booking has no buttons |
| 9 | Pass | Second `accessTokens` document with `delegatedTo` set to the neighbour |
| 10 | Pass | Document gone, the neighbour's shared booking disappeared |
| 11 | **Fail** | The neighbour cannot open the locker at all. See below |
| 12 | Pass | The app reported it could not reach the service and did not crash |

Steps 5, 7 and 8 were each refused by the interface before the server could refuse them.
That is defence in depth working, and it means **a test driven through the interface cannot
exercise the server's refusal paths at all.** Reaching them needs a direct call to the
endpoint, which is what was done instead:

```powershell
$body = '{"data":{"payload":"forged.not.a.real.code","stationId":"S1","compartmentId":"S1-B1"}}'
Invoke-RestMethod -Uri "http://127.0.0.1:5001/demo-scls/australia-southeast1/handleScan" `
  -Method Post -ContentType "application/json" -Body $body
```

The server returned `decision: invalidSignature` and wrote an `accessLog` entry with
`presentedBy`, `reservationId` and `tokenId` all null. It stopped at the signature and
looked nothing else up, which is the behaviour E4 asks for.

The other three refusals (expired, already used, booking not openable) are covered
server-side by `accessPolicy.test.ts` and `access_policy_test.dart`, which check the
boundary to the second in both languages. They are not covered end to end.

## Step 11: the neighbour cannot open a locker handed to them

Reproduced twice, including once on a fresh booking with a single hand-over, so it is not
caused by repeating the hand-over.

The neighbour's screen calls `requestToken()`, which asks the server for a **new** code.
`issueAccessToken` refuses because the caller is not the booking's owner, and returns
"That booking no longer exists" — the same message a missing booking gets, so the screen
cannot be used to probe other people's bookings. The in-memory implementation refuses for
the same reason, so this has never worked in either build.

Fixing the call is not enough. The delegated code is created when the owner presses the
button and lives for 120 seconds, so the neighbour would have two minutes from the owner's
decision to reach the locker. **The hand-over issues a short-lived credential to somebody
who is not there yet.** The requirement needs a standing grant that the neighbour redeems
for their own code on arrival, which is the model FR4 already uses for the owner.

Recorded as a limitation rather than fixed, with the deadline 35 hours away.
