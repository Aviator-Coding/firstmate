---
name: jev-decide
description: Get a second opinion from TypeSafe Jev, a structured decision model, before bothering your user with a crucial decision you are genuinely unsure about. Use when you face a consequential choice between two or more concrete options and cannot settle it from the code, docs, tests, or the user's stated intent. Act on a decided answer and say Jev decided it; bring an inconclusive answer to your user. Never use it for approvals the user reserves, such as merges, destructive or irreversible actions, security-sensitive choices, or credentials.
---

<!-- maintainers: this is a public, installer-facing skill. Keep it standalone: no private project paths, hostnames, or environment branching. Firstmate reaches it through bin/fm-decide.sh; keep firstmate specifics there and in firstmate's own AGENTS.md, not here. -->

# jev-decide

Before you interrupt your user with a hard call, ask Jev.
Jev is TypeSafe's decision model: given a question and a set of labeled options, it returns one choice, a probability for every option, and a confidence.
The bundled CLI sends one request through your LiteLLM proxy (or straight to OpenRouter), applies a strict verdict rule, and tells you whether the answer is `decided` or `inconclusive`.
You act on `decided`; you bring `inconclusive` to your user.
The CLI never picks an option on its own: any doubt, error, or missing setup comes back `inconclusive`.

## When to use it

Use it when all of these hold:

- The decision is consequential enough that getting it wrong costs real rework, and you would otherwise stop to ask your user.
- You have two or more concrete, mutually exclusive options you can describe in a sentence each.
- You cannot settle it by reading the code, docs, tests, or the user's stated goals, or by running a quick experiment.
- The decision is yours to make: nobody has reserved it for the user.

Do not use it for trivial or easily reversible choices; just make them.

## Never ask Jev about these

These always go to your user, whether or not Jev has an opinion, and a `decided` verdict grants none of them:

- Merging, releasing, deploying, or publishing anything that needs the user's approval.
- Destructive or irreversible actions: deleting data or work, force-pushing, dropping history, discarding changes.
- Security-sensitive choices: permissions, access, exposure, secrets handling, weakening a safeguard.
- Credentials and logins: which account, key, or identity to use, or whether to create or share one.
- Anything your user, project rules, or an approval gate reserves for the user, including product or scope choices they asked to make themselves.

Do not consult Jev on these at all, so its answer cannot anchor the question you put to your user.

## Procedure

1. **Frame the decision.**
   Write the question as one instruction ("Which cache backend should the pager use?").
   Give each option a short label and a one-sentence description of what choosing it means.
   Add context: the relevant facts, constraints, and the user's stated goals, in plain prose.
   State the user's priorities in their own words, as they actually said them.
   State what each option really costs, whether it is reversible, and who is affected.
   Give every option its upside and its downside, worded in the same neutral way.
   Do not word anything to lean toward the answer you already expect.
   If you cannot state the user's priorities from what they actually said, stop and ask your user instead of Jev.
   Thin context gets a thin answer: a question asked with no priorities, no cost of waiting, no key owner, and uneven option wording came back inconclusive at confidence 0.23 leaning "wait", while the same question with those facts came back decided "open" at 0.95.
   Keep the fuller version honest: phrases like "easy to tighten later" push toward an option, so state facts, not persuasion.
   Everything you send leaves your machine through the proxy to a third-party model, so never include secrets, credentials, private keys, or personal data in the question, options, or context.
2. **Ask.**
   Run `scripts/jev-decide.sh --question "<question>" --option "<label>=<description>" --option "<label>=<description>" --context "<context>"` from this skill's directory (add more `--option` flags as needed, `--context-file <path>` for long context, `--json` for machine output).
   `scripts/jev-decide.sh --help` owns every flag, the environment variables, the confidence floor and top-two margin, and the output format.
3. **Act on the verdict.**
   - `decided`: go with Jev's `choice`.
     In your report or summary, say that Jev decided it and give its confidence, for example "Jev decided `assoc-array` (confidence 0.92)".
   - `inconclusive`: do not act on the `leaning`.
     Bring the question to your user with the options, Jev's leaning, confidence, and probabilities when present, the `reason`, and your own recommendation.
4. **Exit code 2** means your invocation or a tuning variable is wrong; fix it and ask again, or treat the decision as inconclusive if you cannot.

## Setup

The CLI needs `bash`, `curl`, and `jq`, plus two environment variables:

- `JEV_DECIDE_BASE_URL` - your LiteLLM proxy's base URL, for example `https://litellm.example.com`.
- `JEV_DECIDE_API_KEY` - a proxy key allowed to call the decisions route.

The default path is `/openrouter/alpha/decisions`, LiteLLM's built-in OpenRouter pass-through, which forwards to OpenRouter's decisions API (Jev is served only there, not on chat completions).
If your proxy exposes a different door, set `JEV_DECIDE_PATH`; to call OpenRouter directly, use base `https://openrouter.ai/api` with path `/alpha/decisions` and an OpenRouter key.
Without a base URL or key, every call returns `inconclusive` with a "not configured" reason, so an unconfigured install safely routes every decision to your user.
A "credential not granted" reason (HTTP 403) means the key is valid but the proxy has not allowed it on the decisions route; ask the proxy's operator to grant it.
