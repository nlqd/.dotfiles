---
name: pr-comments-replies
description: Use this when user wants to respond to PR comments. Use `gh` under the hood
---

## RESPONDING TO PR COMMENTS

When asked to reply to PR comments on your behalf:

### (Optional) 1. Fetch PR Information and Comments

Run the `gh-pr-comments` command ONLY IF you do not have this info.

### 2. Reply Using Correct API Endpoint

Use this to submit the comments

```
gh api graphql \
  --field threadId1=\
  --field body1="Thanks, fixed!" \
  --field body2="Good catch, updated." \
  --field body3="Done, see latest commit." \
  --raw-field query='
    mutation($threadId1: "PRT_kwDOABC123", $body1: String!, $threadId2: "PRT_kwDOABC456" , $body2: String!, $threadId3: "PRT_kwDOABC789", $body3: String!) {
      reply1: addPullRequestReviewThreadReply(input: {
        pullRequestReviewThreadId: $threadId1, body: $body1 }) { comment { id } }
      reply2: addPullRequestReviewThreadReply(input: {
        pullRequestReviewThreadId: $threadId2, body: $body2 }) { comment { id } }
      reply3: addPullRequestReviewThreadReply(input: {
        pullRequestReviewThreadId: $threadId3, body: $body3 }) { comment { id } }
    }'
```

### 3. Tone and Style

Avoid:
- Excessive exclamation marks
- Overly enthusiastic language
- Unnecessary pleasantries
- Emoji. Emoji is evil

Include:
- Technical reasoning for decisions
- Openness to alternative approaches
- Specific tradeoffs considered

4. Common Response Patterns

For code style suggestions:
"Good point. I went with [approach] because [technical reason]. Happy to change to [alternative] if you think it's clearer."

For architectural questions:
"The intent was [goal/purpose]. [Explain tradeoff]. We can [alternative] if you'd prefer [different outcome] though."

For questions about missing features:
"I considered [feature] but opted not to include it because [reason]. We can add it if [condition]."

5. Before Sending

- Keep responses concise (2-3 sentences max). Offer alternatives when appropriate.
- Match the reviewer's level of formality
- List out the replies for the human to verify in a temp file (/tmp/pr-replies.md) so that he can edit. Add some context so he knows what he is replying to.
- Why many words when few words do trick?

### 4. Clean up

If it is resolved, AFTER pushing the commits and REPLIED to the reviewers and we don't need anymore follow up, mark them as resolved. Example:

```
gh api graphql -f query='
  mutation {
    t1: resolveReviewThread(input: {threadId: "PRRT_kwDOPZASLs5jwamU"}) {
      thread { isResolved }
    }
    t2: resolveReviewThread(input: {threadId: "PRRT_kwDOPZASLs5jwamd"}) {
      thread { isResolved }
    }
    t3: resolveReviewThread(input: {threadId: "PRRT_kwDOPZASLs5jwamr"}) {
      thread { isResolved }
    }
    t4: resolveReviewThread(input: {threadId: "PRRT_kwDOPZASLs5jwam5"}) {
      thread { isResolved }
    }
  }')
```
