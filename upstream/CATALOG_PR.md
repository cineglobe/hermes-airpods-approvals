# Add airpods-approvals: answer Hermes approvals with your head

Hackathon entry. Adds `plugin-catalog/airpods-approvals.yaml`, pinned to a full commit SHA.

## What it does

When Hermes needs an approval or asks a question, it's read aloud in your AirPods. You answer with a nod or a shake, and the answer drives the real approval. This needs native head motion, per-ear audio feedback and live approval handling, so it isn't something a prompt or skill could do.

## Disclosure

- **Native helper:** head motion needs a real macOS app, so the plugin ships Swift source in `helper/`, built by `scripts/install-helper.sh` on the user's Mac. No binary is committed and nothing is downloaded (rule 17). It needs the Xcode Command Line Tools.
- **Background process:** the helper runs in the menu bar while Desktop is connected, and quits 10 minutes after Desktop goes away.
- **Local connection:** it listens on `127.0.0.1:47291`. Plugin and helper prove they hold a pairing token with HMAC, and browser origins are refused.
- **Network:** none by default. With an optional Gemini key on the Hermes backend, the sentence being read goes to `generativelanguage.googleapis.com`. That includes the approval's description and Hermes-redacted command.
- **Credentials:** read through `agent.secret_scope`. The key never leaves the backend.
- **Approvals (rule 12):** Hermes decides what needs asking. The plugin only passes on a completed human gesture through `approval.respond`, as `once` or `deny`, after rechecking that the same request is still waiting. Timeouts and failures send nothing, so the prompt stays on screen and Hermes' timeout denies it. On-screen buttons keep working.
- **Reads outside its own data:** session lists and pending approvals, through Hermes' RPC.
- **Telemetry:** none.

## Checks

`hermes plugins validate` passes at the pinned commit: security scan safe, no core override, desktop surface inside the SDK.

Tests cover the gesture rules against a real recording, every way an answer can fail to reach Hermes, and the helper handshake.
