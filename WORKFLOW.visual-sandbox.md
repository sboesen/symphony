---
tracker:
  kind: linear
  endpoint: https://api.linear.app/graphql
  api_key: $LINEAR_API_KEY
  project_slug: 0641b6dad9cb
  active_states: [Todo, In Progress]
  terminal_states: [Closed, Done, Cancelled, Canceled, Duplicate]
polling:
  enabled: false
  interval_ms: 300000
workspace:
  root: /tmp/symphony-visual-sandbox-workspaces
hooks:
  after_create: |
    if [ ! -d .git ]; then
      git clone https://github.com/sboesen/symphony-visual-sandbox .
      git checkout main || true
    fi
agent:
  max_concurrent_agents: 2
  max_turns: 1
  max_retry_backoff_ms: 10000
codex:
  command: opencode
  providers:
    codex:
      backend: opencode
      command: opencode
      auth_mode: api_key
      api_key: $Z_API_KEY
      base_url: https://api.z.ai/api/coding/paas/v4
      model: zai-coding-plan/glm-5
  router:
    enabled: true
    default_provider: codex
    hard_provider: codex
    default_model: zai-coding-plan/glm-5
    hard_model: zai-coding-plan/glm-5
    hard_effort: xhigh
    hard_percentile: 95
server:
  port: 4014
github:
  webhook:
    secret: $GITHUB_WEBHOOK_SECRET
    auto_register: true
    provider: ngrok
    repo: sboesen/symphony-visual-sandbox
linear:
  webhook:
    secret: $LINEAR_WEBHOOK_SECRET
    auto_register: true
recording:
  enabled: true
  url: http://127.0.0.1:3000
  ready_url: http://127.0.0.1:3000
  setup_command: |
    if [ ! -d node_modules ]; then
      npm install --no-fund --no-audit
    fi
    npm run dev -- --host 127.0.0.1 --port 3000 --strictPort
  output_dir: .symphony/artifacts/recordings
  wait_ms: 2500
  ready_timeout_ms: 120000
  trace: true
  strict: true
  publish_to_tracker: true
  publish_comment: true
review:
  pr:
    enabled: true
    draft: false
    auto_merge: false
---
You are the coding agent working this ticket.

Issue: {{ issue.identifier }} - {{ issue.title }}
Attempt: {{ attempt }}
Issue URL: {{ issue.url }}
Recent comments:
{{ issue.comments_text }}

Execution contract:
1. Make one focused implementation pass for this issue in the current repo workspace.
2. If the issue is underspecified, make the most reasonable concrete improvement and proceed.
3. Do not run any tests, build commands, dev servers, or watcher commands.
4. If the acceptance condition is already implemented, make no changes and output a concise completion summary immediately.
5. Treat recent issue comments as the primary source of rework feedback if the issue was moved back into active work.
6. When the implementation appears complete, hand off for human review rather than self-closing the work.
7. Do not wait for further user input; finish the turn.
8. Follow the explicit Symphony phase order: `plan -> execute -> demo`.

Completion contract:
- Before implementation, write `.git/symphony/plan.json`.
- Before ending a turn, write `.git/symphony/result.json`.
- Keep `.git/symphony/plan.json` updated so the Symphony workpad comment can be checked off as work progresses.
- A `completed` result is only valid when every plan step is marked `completed`.
- Required JSON shape:
  - `status`: `completed`, `needs_more_work`, or `blocked`
  - `summary`: short summary of what happened
  - `tests`: list of validation commands you ran
  - `artifacts`: optional list of relevant artifact paths or links
  - `notes`: optional follow-up or blocker details
- Symphony treats this file as the source of truth for whether to continue, hand off, or surface a blocker.

Plan contract:
- `.git/symphony/plan.json` must be valid JSON.
- Required JSON shape:
  - `summary`: short summary of the approach
  - `steps`: list of plan steps
- Each step must include:
  - `id`: stable identifier like `1` or `2.1`
  - `content`: human-readable checklist text
  - `status`: `pending`, `in_progress`, `completed`, or `blocked`
  - `children`: optional nested steps
- Symphony syncs this plan to a single managed workpad comment in Linear.
