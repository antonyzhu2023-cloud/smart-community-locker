# Development log

One or two lines per working session. What I did, what broke, what I changed my mind about.

**Why this file exists:** Milestone 2 sections 3.1, 3.2 and 5 all ask for reflection —
issues encountered, how the process worked out, what the experience says about building
next-generation mobile systems. That reflection is only credible if it is dated and
specific. Written at the end from memory it turns into invented narrative, and a marker
can tell. Ten minutes a week here is the cheapest marks in the whole assignment.

Record especially:
- anything that took much longer than expected, and why
- a decision from Milestone 1 that turned out to be wrong or awkward in practice
- a tool or library that fought back
- anything you had to cut, and what you cut it for

---

## Sprint 0 — setup

### 2026-10-01
- Created the GitHub repository. Decided to set up the repo, the board and CI *before*
  writing any feature code, so the process evidence accumulates from the start rather than
  being reconstructed at the end.

### 2026-10-02 — toolchain day
Five toolchains installed on Windows 11: Flutter SDK, Android Studio with the Android SDK
and emulator, Node.js, Firebase CLI, Python. `flutter doctor` is clean and the default
counter app runs on the emulator.

Three things cost real time and are worth recording, because they are evidence for the
future-work section rather than just complaints:

1. **Android Studio defaulted to API 37 (Android 17).** Flutter has an open report of build
   failures against SDK 37 on Windows, and the current ecosystem standard is `compileSdk`
   36, so API 36 was installed alongside it. The tooling offers the newest platform by
   default with no indication that the framework does not support it yet.
2. **The emulator failed to start silently.** `flutter emulators --launch` returned with no
   output and no window. Running the emulator binary directly showed the real cause: a
   previous attempt had left a zombie process, so the AVD appeared to be already running,
   and `adb` reported the device as `offline`. Flutter swallowed the underlying error.
   Fixed by killing the process, clearing the AVD lock files, and cold-booting with
   `-no-snapshot-load`.
3. **Gradle could not install the NDK automatically.** The build needs NDK 28.2.13676358,
   and the automatic install failed because `sdkmanager` is mid-migration to the new
   Android CLI. Installing it by hand through the SDK Manager fixed it.

None of this is application work, but it took most of a day. The pattern in all three is
the same: a layered toolchain where the top layer reports a symptom and hides the cause.

### 2026-10-02 — skeleton and the first green CI run

Wrote the MVVM skeleton: five domain models, the `LockerRepository` interface with an
in-memory implementation, `StationListViewModel`, and the station list screen. Dependencies
are injected in `main.dart` through `provider`. Then wrote the tests: 60-odd cases over the
models, the repository and the ViewModel, plus four widget tests.

Three things worth recording:

1. **Writing the tests changed the production code twice.** `isEmpty` originally returned
   true while an error was showing, which would have told the user "no lockers here" when
   the real problem was the network. And `setSizeFilter` notified listeners even when the
   value had not changed. Neither would have been found by using the app. This is the
   argument for the testable seam in the Milestone 1 design working in practice, not just
   on paper.
2. **The CI workflow written in advance did not run.** Two faults. The `functions` job
   pointed at a directory that does not exist yet, so it failed before the app job
   mattered; it is deferred to Sprint 2. And the coverage gate used `lcov --extract`, but
   the runner now ships lcov 2.x, which rejects the generated `lcov.info` in strict mode.
   Replaced with an `awk` parse of `lcov.info`, which has no dependency to install and no
   version to drift.
3. **Riverpod replaced by `provider` + `ChangeNotifier`** as planned on 1 October. The
   ViewModel is a plain `ChangeNotifier` with the repository passed through the
   constructor, so every ViewModel test builds it directly with a fake. No Firebase, no
   network, no widget. Milestone 1's claim that MVVM is what makes QR6 reachable is the
   one design decision that has clearly paid for itself so far.

FR2 is formally cut here: the GPS map becomes a plain list. A map needs the Maps SDK, an
API key and runtime location permission, which is the largest amount of unfamiliar work for
the smallest marking return. It was already on the design variation list; it is now real.

Two more faults found after the screenshot above, both worth recording because of
*how* they were found:

4. **The coverage gate passed locally only by accident of path separators.** `lcov.info`
   written on Windows uses backslashes; the Linux runner writes forward slashes. The gate
   matched forward slashes only, so on this machine it reported "no lines found" and failed
   loudly. Had it been written the other way round it would have matched nothing on CI and
   silently passed with zero coverage measured. A quality gate that can fail open is worse
   than no gate. Now matches both. Local figure: 94.44% on viewmodels and repositories.
5. **An offline station still printed its free count.** 76 passing tests did not catch it,
   because every one of them asserts on data, and the fault was that two pieces of correct
   data contradicted each other on screen. Found in about four seconds of looking at the
   emulator. A regression test was added afterwards. This is the clearest evidence so far
   for why the usability evaluation in Section 4 is not optional: automated tests check
   what was specified, and this was never specified.

**Sprint 0 closed.** First push, CI run #1 green in 1m56s: formatting check, static analysis,
77 tests, coverage gate. Nothing application-facing was built, but the pipeline that will
judge everything after this is now in place and has been proved to run.

One last environment fault before the push, worth one line because it is the same shape as
the other four: `git` was installed and working but had no identity configured, and
`adb` was installed and working but not on `PATH`. In both cases the tool above it
(`flutter doctor`, the GitHub docs) reported everything healthy. Five of the six problems in
this sprint were a working component that a neighbouring component could not reach.

- _(continue here)_

---

## Sprint 1 — FR1 auth, FR2 discovery, FR3 booking

### 2026-10-05 — FR1 against an interface, before Firebase exists

Wrote the whole auth feature without a Firebase project: `AuthRepository` interface,
`InMemoryAuthRepository` with a seeded community roll of four membership codes,
`AuthViewModel`, a combined sign-in / register screen, a membership verification screen,
and `RootView` to choose between them. 123 tests pass, `flutter analyze` clean.

Deciding to build against the interface first was the right call for a reason that was not
obvious when planning. It is not only that Firebase setup can happen in parallel. It is
that writing the fake forced the auth *rules* to be stated explicitly — minimum password
length, one claim per membership code, case-insensitive email — before any of them could be
hidden inside a service's default behaviour. When the Firebase implementation arrives, those
same tests become the specification it has to satisfy.

Two decisions worth reporting:

1. **E1 was made structural.** Milestone 1 wrote the rule as "an unverified account cannot
   book", which invites an `if` on the booking button. Instead `RootView` selects the screen
   from auth state and the three screens have no navigation between them, so an unverified
   account cannot reach the locker list at all. The tests in `root_view_test.dart` assert on
   reachability rather than on error messages. A rule that cannot be routed around is worth
   more than a rule that is merely checked.
2. **A wrong membership code at registration refuses the whole registration, but omitting
   the code does not.** Mistyping one character should not permanently cost someone their
   own email address; someone who leaves it blank knows they do not have a code yet. The two
   cases look similar in a requirements document and are not similar to a user.

Also found that the `AuthViewModel` first written updated its user only through the
repository's auth-state stream. Stream delivery is asynchronous, so any caller that awaited
a sign-in and then read `isSignedIn` was depending on microtask ordering. It happened to
pass. Changed to read the session back synchronously once the call returns, with the
subscription kept for changes originating elsewhere. Timing bugs that pass are the ones
worth hunting; this one would have surfaced only under a slower backend, which is exactly
what Firebase will be.

### 2026-10-06 — FR3, and a gap the coverage gate could not see

Booking, cancelling and extending. `BookingRepository` with an in-memory
implementation, two ViewModels, three screens. The concurrency rule from evaluation
criterion E3 is enforced by keeping the check-and-hold free of `await`, and tested by
firing ten bookings at one compartment and asserting exactly one wins.

The thing worth recording is not the feature. It is that the screens were written with no
widget tests at all, and nothing caught it. `flutter test` reported the same 183 passing
cases as before the screens existed, because a count of passing tests says nothing about
what was never written. `flutter analyze` was clean. The coverage gate was green.

The gate was green because it measures `lib/viewmodels/` and `lib/repositories/` only.
Excluding `lib/views/` was a reasonable decision in Sprint 0, when the views held nothing
but layout and measuring them would have inflated the number without testing anything.
By this sprint the views had grown a cancel-confirmation dialog, whose two branches are
real logic, and the kind of logic that looks correct from the outside when it is wired the
wrong way round. The exclusion had quietly turned from a sensible scope into a blind spot,
and a gate that reports a percentage cannot tell you that the thing it is not measuring has
changed.

Caught by the developer asking why the test count had not moved, not by any tool. Twenty-five
widget tests added afterwards, including one that asserts "Keep it" leaves the booking alone.

The gate was then changed to measure the whole of `lib/` rather than a named list of
directories, because the fault was not that views went unmeasured. The fault was that the
scope was hand-maintained, so it could go stale without anything reporting it, and any
directory added later would be unmeasured by default. Measuring everything removes that
class of failure. The QR6 layers are still reported and gated separately so the requirement
can be evidenced directly. Measured figures: whole of `lib/` 94.10%, QR6 layers 94.79%,
`lib/views/` 95.34% — the views turned out to be the best-covered layer in the project, so
widening the gate relaxed nothing. The gate was also run against a doctored `lcov.info` with
every line marked uncovered, to confirm it actually fails; the earlier path-separator bug
existed because the gate itself had never been tested.

### 2026-10-06 — two defects found by reading the demo screenshots

Both were in the screenshots taken for the report, and neither was reachable by the tests
that existed:

1. The stay options read "2 hours / 1 days / 3 days".
2. A cancelled booking read "Ended Tue 6 Oct, 02:10" — a time it never reached, because it
   was given up hours earlier. The data was correct and the sentence was not. The widget
   tests asserted that the state became `cancelled` and that the row moved to the Finished
   group, and both of those were already right, so nothing failed.

This is the second time in two days that looking at the running app found something the
suite could not. It is a concrete argument for the heuristic evaluation planned in Section
4 rather than a rhetorical one: automated tests check what somebody thought to specify, and
nobody specifies the wording of a sentence until they read it. Regression tests for both
were added afterwards, which is the right order — the test documents the defect, it does
not discover it.

- _(continue here)_

---

## Sprint 2 — FR4/FR5 access slice, FR7 hand-over

### 2026-10-07 — the access slice, and a clock in two places

FR4 and FR5. `AccessPolicy` holds the rules as a pure class with no IO, so the four
refusals evaluation criterion E4 names are four calls to one method. `LockerCommandGateway`
is the seam Milestone 1 named as critical, and it has no `open(compartmentId)` method
because the application never opens a locker. It presents a credential and the server
decides.

Seven tests failed on the first run of the access screen, all from one cause. The backend
minted tokens using the real clock while the ViewModel judged them against an injected
fake one, so every token looked expired the instant it was issued. The dependency
injection had been done halfway. A system with two sources of time will eventually have
two opinions about what time it is. The clock is now injected all the way down.

A second failure was different in kind. A test asserted that an accepted code with no door
report yet counts as waiting, and it could not pass, because the in-memory cabinet answered
in the same instant it was asked. The state being asserted had a duration of zero. Added
`doorReportDelay` so the cabinet takes time to reply, which is also closer to a real one.
The demo build uses three seconds so the state can be read in a screenshot, and any figure
showing it has to say so.

### 2026-10-07 — FR7, and four words that were in the requirement but not in the code

Hand-over. The booking does not change hands: the owner keeps it and keeps their own
access, and the neighbour gets one token for the same booking. One booking, two accounts,
two tokens, each revocable on its own. That shape was already in the Milestone 1 credential
design, which said a booking could hold several tokens.

The test suite found a real defect. FR7 says a hand-over is "revocable **before use**".
`revoke()` checked only that the token existed, so revoking a spent token succeeded. The
operation is harmless, because a used code cannot open anything anyway. The message is not:
the owner taps "Take back", reads "That access has been taken back", and believes the
locker was never opened. It had been.

Four words in the requirement never reached the code. It was caught because the test was
written from the requirement text rather than from the implementation, which is the only
order in which a test can find something the implementer did not already know.

Adding the new dependency to `MyBookingsView` broke twelve unrelated view tests at once.
That was the design working. The dependency is visible, so adding one has a cost that is
paid in the open. Milestone 1 rejected the Singleton pattern for this reason, and the
twelve failures are the bill for that decision rather than evidence against it.

One limitation to carry into section 5: all state is in memory. Restarting the app clears
every account, booking and token, so the hand-over demo has to be run in a single sitting.

---

## Evaluation and report

_(entries)_
