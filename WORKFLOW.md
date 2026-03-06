---
tracker:
  kind: linear
  endpoint: https://api.linear.app/graphql
  api_key: $LINEAR_API_KEY
  project_slug: $LINEAR_PROJECT_SLUG
  active_states: [Todo, In Progress]
  terminal_states: [Closed, Done, Cancelled, Canceled, Duplicate]
polling:
  interval_ms: 1000
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
  command: codex app-server
  providers:
    zai:
      backend: opencode_server
      command: opencode serve
      auth_mode: api_key
      api_key: $Z_API_KEY
      base_url: https://api.z.ai/api/coding/paas/v4
      model: zai-coding-plan/glm-5
    codex:
      backend: opencode_server
      command: opencode serve
      auth_mode: app_server
      model: openai/gpt-5.3-codex
  router:
    enabled: true
    default_provider: zai
    hard_provider: codex
    default_model: zai-coding-plan/glm-5
    hard_model: openai/gpt-5.3-codex
    hard_effort: xhigh
    hard_percentile: 95
server:
  port: 4012
recording:
  enabled: false
  url: http://127.0.0.1:3000
  ready_url: http://127.0.0.1:3000
  output_dir: .symphony/artifacts/recordings
  wait_ms: 2500
  trace: true
  strict: false
  publish_to_tracker: true
  publish_comment: true
review:
  pr:
    enabled: true
    draft: false
    auto_merge: true
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
