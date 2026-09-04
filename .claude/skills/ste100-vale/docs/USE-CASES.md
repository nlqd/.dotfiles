# Beyond documentation

STE was written for aircraft maintenance manuals, and the properties that
make it work there carry over to any text where a misreading costs
something: one meaning per word, short sentences, and the condition before
the command.

Each case below names the text type, because the type sets the sentence
limit and the verb form. Procedures take the imperative and a 20-word limit.
Descriptions take simple tenses and a 25-word limit.

## Error messages and CLI output

Procedure. An error message is an instruction delivered to a stressed reader
at an inconvenient hour, which is close to the original design target.

State what happened in the simple past, give the cause where it is known,
then give the fix as a command.

Before: Oops! Something went wrong while attempting to establish a
connection. Please ensure your credentials are properly configured and try
again.

After: Connection to the database failed. The password for user `app` was
not correct. Set `DB_PASSWORD` and connect again.

Drop the apology, drop "please", and drop "something went wrong" when you
know what went wrong.

## Runbooks and standard operating procedures

Procedure, at the dictionary level if you have the dictionary. An on-call
runbook is a maintenance manual with different hardware.

Every step is imperative and carries one instruction. Conditions come first.
A warning goes before the step it guards, not after. Hold the 20-word limit
strictly here, because an operator under pager stress reads each sentence
once and does not come back to it.

## Incident reports and postmortems

Description, simple past only. A timeline written in the present perfect
hides when things happened, which is the one thing a timeline exists to say.

Before: We have identified an issue that may have impacted some users'
ability to access the service.

After: Between 14:02 and 14:31 UTC, 12% of requests failed. A deploy at
14:00 removed the cache warmup step.

STE has no room for hedges, so the report states what is known and says
"unknown" for the rest. That reads as more honest because it is.

## Commit messages and pull request descriptions

Imperative subject, descriptive body. The usual convention already matches
STE. Apply the 25-word limit to the body and delete "this PR aims to".

## Release notes and API changelogs

Description. One entry, one change, one sentence where the change allows it.
A breaking change follows the warning shape, command first and consequence
second: "Update your calls to `v2/users`. The `name` field split into
`first_name` and `last_name`."

## Instructions written for other agents

Procedure. A system prompt, an `AGENTS.md`, or a skill file is a procedure
for a reader that cannot ask a clarifying question, which is the reader STE
was designed for.

One instruction per sentence keeps each rule independently quotable and
hard to half-follow. One word per concept stops a model from reading
"check", "verify", and "validate" as three different operations. Put the
condition first, because a trailing condition is the part that gets dropped.
Avoid "should": a model reads it as optional, so write "must" or delete the
line.

## Support macros and status page updates

Description, 25-word limit. Non-native readers are the majority of many user
bases. Cut the apology paragraph: "The API was down for 18 minutes. Uploads
made during this time were saved and will process today."

## Translation and localization preparation

Dictionary level. Making English readable for non-native maintenance crews
was the original job, and it doubles as pre-editing for machine translation.
One meaning per word, plus complete grammar with its articles and its
"that", removes most of the ambiguity a translator would otherwise have to
guess at.

## UI copy and empty states

Procedure, with hard length limits from the layout rather than from the
standard. Buttons and labels are technical names and stay as they are. Body
copy follows the rules: "No projects yet. Create a project to start."

## Where STE does not fit

Marketing pages, launch posts, blog voice, brand writing. STE removes
persuasion on purpose. Write those in your own voice, then use STE for the
documentation the landing page links to.
