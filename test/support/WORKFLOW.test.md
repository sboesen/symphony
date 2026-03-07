---
tracker:
  kind: mock
  mock_file: test/support/mock_issues.json
workspace:
  root: /tmp/symphony-test-workspaces
agent:
  max_concurrent_agents: 1
github:
  webhook:
    secret: test-secret
codex:
  router:
    enabled: false
review:
  pr:
    enabled: false
recording:
  enabled: false
---
Test workflow for unit tests.
