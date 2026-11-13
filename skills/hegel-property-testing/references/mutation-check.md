# Mutation check: does the property catch a bug?

## Goal

Validate the oracle, not the code. A green property shows nothing bad was observed — not that it
would have noticed. For each important safety property, inject one realistic bug designed to break
exactly that property, run the property, and confirm it fails for the predicted reason. Every
survivor gets a diagnosis. The working tree ends with no mutation in it.

With Hegel this is cheap: a mutant is a local edit and a `swift test --filter` run, and the shrunk
counterexample shows directly whether the failure came from the mutant.

## Before starting

- **Green baseline.** The properties in scope pass on the unmutated code. A mutant run against a
  failing property measures nothing.
- **Reach observed.** The baseline statistics show each property's reach claims occurring. A
  property that never reaches its state can't kill any mutant; fix the generator first.
- **A safe working tree.** Mutants live only as patches applied for one run. If the tree has
  uncommitted changes in the files you'll mutate, work in a separate worktree, or save each mutant
  as a patch and reverse exactly that patch.
- **Agree on scope and spend with the user** when the set is large: which properties, how many
  re-runs, and whether test fixes the sweep finds may be applied or only proposed.

## Scope

| Check | Treatment |
|---|---|
| `#expect`/`#require` invariants, `Issue.record` forbidden paths | **Mutate.** A green safety check is the vacuous pass this exists to rule out |
| Reach claims (events, counters) | **Baseline only.** A reach claim that passes already proves the test got there |

## Design one mutant per property

- **A realistic developer mistake:** a dropped guard, `>` for `>=`, an off-by-one, a missing clamp,
  an error swallowed instead of thrown, a check moved outside a lock, a state update after an
  `await` instead of before. Not vandalism: returning garbage proves only that the check exists.
- **Subtle.** It should need a specific prerequisite to show — a full cache, a second writer, a
  failure after a partial write. A mutant that breaks every case dies on the first draw and proves
  nothing about the generators.
- **Non-fatal.** A mutant that traps kills the test process: that is a crash, not a kill.
- **In the code that maintains the invariant, not the code that checks it.** Mutating the check, or
  an `internal checkInvariants()` the test calls, disables the reporting with the behavior.
- **Reachable by the current generators.** If nothing the test draws drives execution to the site,
  the mutant can't die. That's a generator gap — fix the generator, not the mutant.

Consider several candidates and keep the strongest. Note the rejected ones and why.

## Trace the kill chain before running

Write down four links. A survivor with a clean trace means some assumption in the trace was wrong —
and the same wrong assumption is probably in the other traces.

1. **Reach** — which draws drive execution into the mutated code? Name the event or counter that
   proves it.
2. **Diverge** — does the mutated code produce a different state? Watch for convergent mutants:
   the wrong value re-clamped, retried, recomputed or overwritten before anything reads it.
3. **Propagate** — does the divergence reach what the check reads, uncorrected?
4. **Fire** — read the actual predicate, not the property's prose. Does the divergent value make it
   false? A predicate that is too loose, keyed on a coarser quantity, or guarded by a condition the
   mutation disables is an oracle bug.

Finish with a prediction: which check fires (by source location), what the minimal example should
look like, and which other checks may fire as collateral.

## Run it

1. Apply the mutant (`git apply m03-evict-off-by-one.patch`). Optionally add a marker in the
   divergent branch — a `print("[m03] diverged")` to standard error — to prove the bug executed.
2. Run only the property's test, with the database off so the mutant's failure isn't stored and
   replayed later:

   ```bash
   HEGEL_DATABASE=disabled swift test --filter LRUCacheTests/evictionKeepsMostRecent
   ```

   Add `HEGEL_DEFAULT_PROFILE=ci` for derandomized, comparable runs.
3. Revert exactly that patch (`git apply -R m03-evict-off-by-one.patch`) and confirm `git diff`
   shows the tree as it was before. Do this after every run, including failed and interrupted ones.

**Killed** means: the targeted check failed, at its source location, and the minimal example shows
the mutant's mechanism. Other checks failing too is normal; predict them. If most of the suite
fails, the mutant is too broad — narrow it.

## Diagnose survivors

| Evidence | Diagnosis | Action |
|---|---|---|
| The marker never printed; nothing reaches the site | generator gap | widen or add generators, policies or rules that drive there; re-run the baseline and the mutant |
| The site is reached, but the divergence condition rarely occurs | rarity | re-run with `HEGEL_TEST_CASES=10000` before concluding; add `target` or a policy that makes it common |
| The divergence is undone before observation | convergent mutant | choose a different mistake, or move the check to where the divergence is visible |
| The state is wrong, the check still passes | oracle bug | tighten the predicate, re-key it to the diverging state, or check at a different site |
| A different check fired, not the target | off-target or dominated | narrow the mutant; if the target can't break without the other firing, it is redundant, not validated — say so |
| The target fails without the marker printing | pre-existing bug | not a kill: the baseline missed a real bug. Report it |
| The property can't be falsified by any realistic mistake | bad property | refine it with the user, or withdraw it with a recorded reason |

Fix generators and oracles found this way — they are the point of the exercise — then re-run the
baseline and every mutant: a change to the test can turn an earlier kill into a survivor.

## Do not game the loop

- Don't narrow a generator into a deterministic path to force a kill.
- Don't coarsen a subtle mutant into vandalism because it survived; fix the generator or the oracle.
- Rewriting a check to match the mutant that will then validate it is circular. Do it only when the
  check is genuinely wrong, and record it as killed *after refinement*.

## Record

Per property: the mutant (as a patch or a one-line description), the predicted chain, the result,
the diagnosis, and what was fixed. A short table in the catalog or in the test's doc comment is
enough. Mutant patches themselves are scratch: never commit them into the tree, and never leave one
applied.
