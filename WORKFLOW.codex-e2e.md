---
tracker:
  kind: linear
  endpoint: https://api.linear.app/graphql
  api_key: $LINEAR_API_KEY
  project_slug: $LINEAR_PROJECT_SLUG
  active_states: [Todo, In Progress]
  terminal_states: [Closed, Done, Cancelled, Canceled, Duplicate]
polling:
  enabled: false
  interval_ms: 300000
workspace:
  root: /tmp/symphony-e2e/workspaces
hooks:
  after_create: |
    if [ ! -d .git ]; then
      : "${GITHUB_REPO_URL:?set via --repo or GITHUB_REPO_URL}"
      git clone "$GITHUB_REPO_URL" .
      if [ -n "${GIT_DEFAULT_BRANCH:-}" ]; then
        git checkout "$GIT_DEFAULT_BRANCH" || true
      fi
    fi
agent:
  max_concurrent_agents: 2
  max_turns: 1
  max_retry_backoff_ms: 10000
codex:
  command: codex
  providers:
    codex:
      backend: codex_exec
      command: codex
      auth_mode: api_key
      api_key: $OPENAI_API_KEY
      model: gpt-5-codex
  router:
    enabled: true
    default_provider: codex
    hard_provider: codex
    default_model: gpt-5-codex
    hard_model: gpt-5-codex
    hard_effort: xhigh
    hard_percentile: 95
server:
  port: 4012
github:
  webhook:
    secret: $GITHUB_WEBHOOK_SECRET
    auto_register: $SYMPHONY_GITHUB_WEBHOOK_AUTO_REGISTER
    provider: ngrok
    repo: $GITHUB_WEBHOOK_REPO
linear:
  webhook:
    secret: $LINEAR_WEBHOOK_SECRET
    auto_register: $SYMPHONY_LINEAR_WEBHOOK_AUTO_REGISTER
recording:
  enabled: true
  url: http://127.0.0.1:3000
  ready_url: http://127.0.0.1:3000
  setup_command: |
    if [ ! -d node_modules ]; then
      npm install --no-fund --no-audit
    fi
    npm run dev -- --host 127.0.0.1 --port 3000
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
