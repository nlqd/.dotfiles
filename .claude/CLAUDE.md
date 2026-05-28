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
- Data first. Adopt functional programming doctrine where make sense
- Functional core. Imperative shell
- Avoid premature abstractions
- No clever tricks - choose the boring solution
- If you need to explain it, it's too complex
- Hence, it does not warrant a comment on each line. Semantic and simple code needs not comment.
- I repeat. Simple code needs not comment. MAJOR DECISIONS should be commented.

## Technical Standards

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

### Decision Framework

When multiple valid approaches exist, choose based on:

1. **Testability** - Can I easily test this?
2. **Readability** - Will someone understand this in 6 months?
3. **Consistency** - Does this match project patterns?
4. **Simplicity** - Is this the simplest solution that works?
5. **Reversibility** - How hard to change later?

### Learning the Codebase

- Find 3 similar features/components
- Identify common patterns and conventions
- Use same libraries/utilities when possible
- Follow existing test patterns

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
- Push to remote or open PR without explicit permission

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
- Try to be minimal in markdown. Don't bold things out of control. Bold should at most be 1% of the total text only. Same thing with italics.

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
In PR description, use $\rightarrow$ only when it actually means a transition or relation, not as a decorative connector in prose. Try to use LaTeX variants for other unicode symbols if you can.

PR descriptions should read smoothly to a human reviewer. Three rules:
- Default to flowing prose over dense bullet lists. Bullets are for genuinely list-shaped content (test plans, file inventories)
- Code spans (`like_this`) only for real identifiers: file paths, function/symbol names, exact strings being matched. Don't use them for emphasis or topic markers.
- A comma or colon is strongly suggested to be used in place of emdash. Try to maintain a ratio of 100 comma/colon/other symbols to 1 emdash.

### Other QOL improvement

- Bash(gh-pr-comments) gives all comments on the current PR. No need to run with any param as it works ootb.
- Don't merge origin/main. Merge local main
- Don't assume small changes means amend and push force. Only commit as separate.
- When a user asks a general concept question (e.g., 'what is X'), answer the general concept first before diving into project-specific details.
- When the user provides a terse or minimal prompt, ask one clarifying question before proceeding rather than guessing the intent. But for clearly scoped tasks, proceed without asking.
- When refactoring, for readability reason, please collocate variable w/ where they are used, so the reading flow from top to bottom is more flowish.

- Must use these following skills at the beginning of any conversation:
   - Skill(fast-code-search)
   - Skill(ops-room)
- Should use these skills:
   - Skill(rodney): for when web fetch is blocked (bot blocking) -- rodney would help you circumvent that
