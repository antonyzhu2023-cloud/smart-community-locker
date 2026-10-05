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

_(entries)_

---

## Sprint 2 — FR4/FR5 access slice, FR7 hand-over

_(entries)_

---

## Evaluation and report

_(entries)_
