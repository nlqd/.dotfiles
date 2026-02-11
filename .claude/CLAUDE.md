# Development Guidelines

Cite: dzombak.com

When you understand the rules, please start with "I UNDERSTAND THE GLOBAL ORDER".

## Philosophy

### Core Beliefs

- **Incremental progress over big bangs** - Small changes that compile and pass tests
- **Learning from existing code** - Study and plan before implementing
- **Pragmatic over dogmatic** - Adapt to project reality
- **Clear intent over clever code** - Be boring and obvious

### Simplicity Means

- Single responsibility per function/class
- Avoid premature abstractions
- No clever tricks - choose the boring solution
- If you need to explain it, it's too complex
- Hence, it does not warrant a comment on each line. Semantic and simple code needs not comment.
- I repeat. Simple code needs not comment. MAJOR DECISIONS should be commented.

## Process

### 1. Planning & Staging

IF THE WORK IS COMPLEX, break complex work into 3-5 stages. Document in `IMPLEMENTATION_PLAN.md`:

```markdown
## Stage N: [Name]
**Goal**: [Specific deliverable]
**Success Criteria**: [Testable outcomes]
**Tests**: [Specific test cases]
**Status**: [Not Started|In Progress|Complete]
```
- Update status as you progress
- Remove file when all stages are done

### 2. Implementation Flow

1. **Understand** - Study existing patterns in codebase
2. **Test** - Write test first (red)
3. **Implement** - Minimal code to pass (green)
4. **Refactor** - Clean up with tests passing
5. **Commit** - With clear message linking to plan, only AFTER the human in the loop is satisfied, or if he explicitly allows you to run wild.

### 3. When Stuck (After 3 Attempts)

**CRITICAL**: Maximum 3 attempts per issue, then STOP.

1. **Document what failed**:
   - What you tried
   - Specific error messages
   - Why you think it failed

2. **Research alternatives**:
   - Find 2-3 similar implementation
   - Look up similar issues online, using agents to search for you
   - Note different approaches used

3. **Question fundamentals**:
   - Is this the right abstraction level?
   - Can this be split into smaller problems?
   - Is there a simpler approach entirely?

4. **Try different angle**:
   - Different library/framework feature?
   - Different architectural pattern?
   - Remove abstraction instead of adding?

## Technical Standards

### Architecture Principles

- **Composition over inheritance** - Use dependency injection
- **Interfaces over singletons** - Enable testing and flexibility
- **Explicit over implicit** - Clear data flow and dependencies
- **Test-driven when possible** - Never disable tests, fix them

### Code Quality

- **Every commit must**:
  - Compile successfully
  - Pass all existing tests
  - Include tests for new functionality
  - Follow project formatting/linting

- **Before committing**:
  - Run formatters/linters
  - Self-review changes
  - Ensure commit message explains "why"

### Error Handling

- Fail fast with descriptive messages
- Include context for debugging
- Handle errors at appropriate level
- Never silently swallow exceptions

## Decision Framework

When multiple valid approaches exist, choose based on:

1. **Testability** - Can I easily test this?
2. **Readability** - Will someone understand this in 6 months?
3. **Consistency** - Does this match project patterns?
4. **Simplicity** - Is this the simplest solution that works?
5. **Reversibility** - How hard to change later?

## Project Integration

### Learning the Codebase

- Find 3 similar features/components
- Identify common patterns and conventions
- Use same libraries/utilities when possible
- Follow existing test patterns

### Tooling

- Use project's existing build system
- Use project's test framework
- Use project's formatter/linter settings
- Don't introduce new tools without strong justification

## Quality Gates

### Definition of Done

- [ ] Tests written and passing
- [ ] Code follows project conventions
- [ ] No linter/formatter warnings
- [ ] Commit messages are clear
- [ ] Implementation matches plan
- [ ] No TODOs without issue numbers

### Test Guidelines

- Test behavior, not implementation
- One assertion per test when possible
- Clear test names describing scenario
- Use existing test utilities/helpers
- Tests should be deterministic

## Important Reminders

**NEVER**:
- Use `--no-verify` to bypass commit hooks
- Disable tests instead of fixing them
- Commit code that doesn't compile
- Make assumptions - verify with existing code

**ALWAYS**:
- Commit working code incrementally
- Update plan documentation as you go
- Learn from existing implementations
- Stop after 3 failed attempts and reassess. Do 1-2 web search if you feel like you desperately need it.
- Leave code obvious. Need no comment if code simple for grug.
- Craftsmanship
- Also, if you want, you can use `fzf` if standard grep fails to find the name
   that you want. `fzf` has a --filter mode where it can fuzzily filter the
   filename for example. Also I have `rg` on my system which is a faster grep.
- Only commit what you changed
- Also look at @.claude/CLAUDE.md
- Also, use long flags in bash commands so I know what ur doing
- When in investigative/explorative/debugging session, use liberally the AGENTS available to you.
  For example, when debugging, ask 2 agents to argue for and against you.

## Git and GitHub works

### Commit message format

Use conventional commit with at most 3 lines of description, only if the commit has complex change.
If it is straightforward that an undergrad can understand, then please don't write desriptions.

Separate first line of commit from the rest (so feat:... \n\ncontent....).
Start each line of desc with a dash.

If this commit handles other comments, paste the comment's url into the commit

If your task is in Asana, add it add the end
https://app.asana.com/0/0/<task_id>

### Pull Request Description Format

Title: should be the task's name

```
### Task

[task name](task link)
... other tasks if this PR handles multiple tasks...

### What we have done

- max 5 lines of description, ONLY if the git change has complex change
- if the change is trivial, please don't add description
```

Avoid using emojis except for when it's in task name.
In PR description, for arrows, I prefer $\rightarrow$ instead of the unicode arrow. Try to use Latex variants for other unicode symbol if you can.

### Some provided wrappers

- Bash(gh-pr-comments) gives all comments on the current PR. No need to run with any param as it works ootb.
- Don't merge origin/main. Merge local main
