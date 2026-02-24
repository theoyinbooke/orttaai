# Orttaai Build Loop — Ralph Prompt

You are building **Orttaai**, a native macOS voice keyboard app. You are in a continuous build loop. Each iteration, you pick up where the last one left off.

## Your Reference Documents

Read these ONLY if you haven't already in this iteration (check if you know the context):

1. **PRD**: `/Users/theoyinbooke/orttaai/orttaai-prd-v2.2.md` — what to build
2. **Implementation Plan**: `/Users/theoyinbooke/orttaai/orttaai-implementation-plan.md` — step-by-step tasks
3. **Design System**: `/Users/theoyinbooke/orttaai/orttaai-design-system.md` — all visual specs and component code
4. **Checklist**: `/Users/theoyinbooke/orttaai/orttaai-checklist.txt` — tracks what's done and what's next

## Your Loop Behavior

Every iteration, follow this exact sequence:

### Step 1: Read the Checklist

Read `/Users/theoyinbooke/orttaai/orttaai-checklist.txt`. Find the FIRST line that starts with `[ ]` (unchecked). That is your current task.

If there are prerequisite tasks above it that are also `[ ]`, work on those first.

### Step 2: Understand the Task

Each checklist item has a task ID (e.g., `TASK-1.1`) that maps to the implementation plan. If you need more context about what the task requires, read the corresponding section in `orttaai-implementation-plan.md` and/or `orttaai-prd-v2.2.md`.

### Step 3: Implement the Task

- Write the code. Create or edit files as specified in the implementation plan.
- Follow the design system exactly — use `Color.Orttaai.*`, `Font.Orttaai.*`, `Spacing.*` tokens.
- Follow the PRD code samples closely — they are production-ready scaffolding.
- Do NOT skip steps. Do NOT implement tasks out of order unless a dependency requires it.
- If a task involves writing tests, write the tests AND run them if possible.

### Step 4: Mark the Task Complete

After implementing a task, edit `/Users/theoyinbooke/orttaai/orttaai-checklist.txt` and change `[ ]` to `[x]` for that task. Also add a brief note with the date if useful.

### Step 5: Commit

After completing each task (or logical group of 2-3 small related tasks), create a git commit:
- Stage only the files you changed
- Write a clear commit message describing what was implemented
- Do NOT push (the user will push when ready)

### Step 6: Check for Completion

After marking a task complete, check if ALL tasks in the checklist are `[x]`.

- If there are remaining `[ ]` tasks: continue to the next task in this iteration.
- If ALL tasks are complete: output the completion promise (see below).

## Rules

1. **One task at a time.** Implement fully before moving to the next.
2. **Read before writing.** If you're editing an existing file, read it first.
3. **Follow the plan exactly.** Don't skip ahead, don't add features not in the PRD, don't refactor code you didn't write.
4. **Test what you can.** If a task includes writing tests, run `xcodebuild test` if the test target is set up. If tests fail, fix them before marking complete.
5. **Keep it building.** After each task, the project should still compile. If you introduce a compile error, fix it before moving on.
6. **Don't over-engineer.** Implement exactly what the PRD specifies. No extras.
7. **If you're stuck**, leave a note in the checklist next to the task with `[BLOCKED]` and the reason, then move to the next non-blocked task.
8. **If you need to create the Xcode project**, the user must do this manually in Xcode. Leave a `[MANUAL]` note and move to tasks that don't require the project structure.

## Verification Checkpoints

At the end of each phase, there is a `CHECKPOINT` entry in the checklist. When you reach it:
- Verify all tasks in that phase are `[x]`
- If any are `[ ]` or `[BLOCKED]`, go back and resolve them before proceeding
- Mark the checkpoint `[x]` only when the phase is truly complete

## Completion Promise

When EVERY item in the checklist is `[x]` — including all 5 checkpoints (CHECKPOINT-SETUP, CHECKPOINT-PHASE1 through CHECKPOINT-PHASE4) — output this:

<promise>ORTTAAI BUILD COMPLETE</promise>

Do NOT output this promise until everything is done. Do NOT fake completion.

## Important Notes

- The Xcode project must be created manually by the user (Task SETUP-4). If it doesn't exist yet, mark it `[MANUAL]` and work on tasks that can be done as standalone `.swift` files.
- SPM dependencies must be added via Xcode (Task SETUP-6). Code that imports these packages won't compile until the user does this.
- Some tasks require runtime testing (audio, hotkey, permissions). Mark these with implementation complete and note `[NEEDS-RUNTIME-TEST]`.
- The project root is `/Users/theoyinbooke/orttaai/Orttaai/` for the Xcode project files.
