# Nielsen heuristic evaluation — worksheet

Fill this in by walking the application on the emulator. Record what you see,
not what you hoped to see. A heuristic evaluation that finds nothing is a
heuristic evaluation that was not done.

**Method.** One evaluator, the developer, working through Nielsen's ten usability
heuristics against the five built features. Each finding gets a severity on
Nielsen's 0 to 4 scale. Single-evaluator inspection catches roughly a third of
the problems a group of five would find, so the count here is a floor and not a
total. Say so in the report.

**Severity scale**

| Rating | Meaning |
|---|---|
| 0 | Not a usability problem |
| 1 | Cosmetic. Fix only if time is spare |
| 2 | Minor. Low priority |
| 3 | Major. Important to fix |
| 4 | Catastrophe. Must be fixed before release |

**Bias.** The developer evaluating their own work will score low and will skip
steps they know by heart. Two guards: walk each flow in the order a first-time
user would, and write the finding down before deciding its severity.

---

## How to run it

1. Restart the application so no account exists.
2. Work through the five flows below in order, slowly.
3. At every screen, ask the ten questions in the next section.
4. Write every finding in the table at the end, even the ones that feel petty.

Flows:

- **A.** Register without a membership code, then verify with `SH-0207`.
- **B.** Register with `WG-1041` straight away.
- **C.** Book a locker, change your mind, cancel it.
- **D.** Book a locker, open it with a code, then try the same code again.
- **E.** Hand a booking to a neighbour, then take it back.

---

## The ten heuristics, as questions to ask at each screen

**H1 Visibility of system status.** Does the screen say what is happening? When
something takes time, is there a sign it is working? After an action, is the
result visible without hunting for it?

**H2 Match between the system and the real world.** Is the wording something a
resident would say? Does anything use a word that only the developer uses?
`Compartment`, `station`, `token`, `delegate`, `reserved`: which of these would a
person in a lobby actually say?

**H3 User control and freedom.** Can a wrong turn be undone? Is there a way back
from every screen? Is anything irreversible without warning?

**H4 Consistency and standards.** Does the same thing have the same name
everywhere? Do buttons in the same position do the same kind of thing? Does the
application follow Android conventions for back, for dialogs, for lists?

**H5 Error prevention.** Are destructive actions confirmed? Can a bad value be
entered at all, or is it refused only after submitting?

**H6 Recognition rather than recall.** Does the user have to remember something
from a previous screen? The membership code, the backup PIN, which compartment
they booked: are these shown where they are needed?

**H7 Flexibility and efficiency of use.** Is the common path short? Is there a
faster route for somebody who uses it daily?

**H8 Aesthetic and minimalist design.** Is anything on the screen that does not
help right now? Does any screen say two things that compete for attention?

**H9 Help users recognise, diagnose and recover from errors.** Do error messages
say what went wrong in plain words? Do they say what to do next? Is any message
a code or an internal term?

**H10 Help and documentation.** Can a first-time user work out what a membership
code is, what a backup PIN is for, or what handing a booking over actually does,
without being told?

---

## Things already known

These were found before the evaluation and are listed so they are not
double-counted. Record them in the table with a note that they predate the
walkthrough.

| # | Finding | Heuristic | Status |
|---|---|---|---|
| K1 | An offline station printed a stale free count next to "Station offline" | H1, H4 | Fixed |
| K2 | A stay length read "1 days" | H4 | Fixed |
| K3 | A cancelled booking read "Ended" with a time it never reached | H2, H9 | Fixed |
| K4 | The access screen said "Ready when you are, get a code" directly above "The door is open, opened with your code" | H1, H8 | Fixed |

All four are wording or status problems rather than logic problems, and all four
were invisible to a test suite that was passing. That pattern is the argument
for doing this at all, and it is worth stating in the report.

---

## Findings

Add a row per finding. Keep the wording specific enough that somebody else could
reproduce it.

| # | Screen | What happens | Heuristic | Severity | Fix now? |
|---|---|---|---|---|---|
| F1 | | | | | |
| F2 | | | | | |
| F3 | | | | | |
| F4 | | | | | |
| F5 | | | | | |
| F6 | | | | | |
| F7 | | | | | |
| F8 | | | | | |

---

## Candidates to look at closely

Not findings yet. These are places where a problem is likely, based on how the
screens were built. Confirm or dismiss each one.

- **The word "compartment".** It appears on five screens. A resident would
  probably say "locker" or "box". H2.
- **The membership code at registration.** A first-time user has no way to know
  what it is or where to get one. The helper text says "from your building
  manager". Is that enough? H10.
- **The backup PIN.** It is shown once, hidden by default, and never explained
  until the user expands it. Would somebody know to look for it when the network
  is down? H6, H10.
- **The three second wait after presenting a code.** The screen says "Waiting
  for the locker". Is three seconds long enough that a user taps again? H1.
- **Cancel versus extend.** Cancel asks for confirmation and extend does not.
  The reasoning is sound but is it visible to the user? H3.
- **The station list after a booking.** The count changes but nothing says why.
  H1.
- **Handing over.** Does the owner understand that they keep their own access?
  The screen says so in one sentence at the top. Is it read? H10.
- **Error wording on a refused code.** "That code was not accepted" is
  deliberately vague for security. Is it too vague to act on? H9 pulls against
  the security decision here, and that tension is worth reporting rather than
  resolving.

---

## After the walkthrough

- Count findings by severity.
- Fix anything at severity 3 or 4 if it is a wording change. Do not start new
  features.
- Anything left unfixed goes into section 5 as a known limitation with its
  severity.
- The full table goes in an appendix. Only the counts and the two or three most
  interesting findings go in the body of section 4.

---

## Result, 25 October 2026

Walked on a Chrome build against the in-memory backend, except F1, which was
observed on 24 October against the Cloud Functions in the emulator.

| ID | Heuristic | Severity | Finding | Fixed |
|---|---|---|---|---|
| F1 | 9. Recognise and recover from errors | 3 | An unclassified server failure reaches the user as its own protocol code, seen as a red banner reading `INTERNAL`. No cause, no next step | No |
| F2 | 2. Match the real world | 2 | Three hand-over strings still said the neighbour "gets one code" after the hand-over became a standing permission. Three tests asserted the old wording, so the build stayed green | Yes |
| F3 | 4. Consistency, 5. Error prevention | 2 | Cancelling a booking asks for confirmation. Giving a locker to a neighbour does not, although only that one cannot be undone | No |
| F4 | 10. Help and documentation | 1 | No help, explanation or "about" on any of the six screens | No |
| F5 | 9. Recognise and recover from errors | 2 | Forged, expired, spent and other people's codes all produce "That code was not accepted." Deliberate, and in direct conflict with criterion E4 | No, by decision |

Four earlier wording defects (stale free count on an offline station, "1 days",
a cancelled booking reading "Ended", two contradictory sentences on the access
screen) were found before this walkthrough and are all fixed. They are listed
in the report so that they are not counted twice.

### Where the heuristics were met

Worth recording, because an inspection that only lists faults is not an
inspection. Heuristic 1 is well served on the access screen, which distinguishes
four door states including "the locker was told to open and the sensor says it
did not move" rather than claiming success on sending the command. Heuristic 9
is met at registration, where a membership code that is not on the list says so.
And the hand-over screen shows who was found before it offers the button, which
is error prevention for the mistake that actually happens, a mistyped address.
