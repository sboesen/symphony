defmodule Symphony.AgentRunnerPrompt do
  @moduledoc false

  alias Symphony.{AgentRunnerDemoContext, Issue, PlanContract}

  def planning_prompt(issue) do
    """
    Create the execution plan for this issue before implementation.

    Issue: #{issue.identifier} - #{issue.title}
    Issue URL: #{issue.url}
    Issue description:
    #{issue.description}

    Recent comments:
    #{issue.comments_text}
    #{issue.feedback_assets_text}

    Write a valid JSON work plan to `.git/symphony/plan.json`.
    Do not make code changes in this planning pass unless the repo already has local work that must be inspected.

    Plan schema:
    {
      "summary": "Short summary of the intended approach",
      "targets": {
        "surface": "Optional short description of the thing being changed",
        "artifacts": ["Optional concrete anchors like routes, files, endpoints, docs pages"]
      },
      "steps": [
        {
          "id": "1",
          "content": "Top-level task",
          "status": "pending | in_progress | completed | blocked",
          "children": [
            {
              "id": "1.1",
              "content": "Sub-step",
              "status": "pending | in_progress | completed | blocked"
            }
          ]
        }
      ]
    }

    Rules:
    - If there are recent human comments, treat them as the latest authoritative correction to the task. They override your earlier attempt, earlier plan text, and any previous implementation that conflicts with them.
    - Ground the plan in the exact user-visible surface named in the issue. Do not substitute a nearby page or component.
    - `targets` is optional. Use it when it helps name the thing being changed, but do not force everything into a route/file shape.
    - If the task clearly names a page, route, endpoint, file, or document, mention that exact thing in either the summary, targets, or step text.
    - Do not include test-running, build-running, or dev-server-running steps when the execution contract forbids those commands. If validation commands are disallowed, plan for code changes and note the validation limitation truthfully.
    - Produce 2-6 top-level steps.
    - Use child steps only when they clarify implementation order.
    - Start everything as `pending`.
    - This plan will drive execution. Prefer editing the plan as reality changes instead of working off a private mental checklist.
    - If you discover a better approach, update the plan structure first and then follow it.
    - If the issue text is ambiguous about the target surface, do not guess. Keep the plan conservative and expect to ask for clarification later instead of silently changing a different page.
    - The plan should be concrete enough that a human can review progress from the checklist alone.
    - The file must be valid JSON with double-quoted keys and strings.
    """
  end

  def append_comment_context(prompt, %Issue{comments_text: text})
      when is_binary(text) and text != "" do
    prompt <>
      """

      Recent human feedback:
      #{text}

      Feedback contract:
      - Treat the latest human comment as authoritative correction to the task.
      - If the latest human comment says the previous attempt was wrong, do not repeat the previous plan or implementation.
      - Prefer satisfying the newest human feedback over preserving an earlier approach.
      """
  end

  def append_comment_context(prompt, _issue), do: prompt

  def plan_repair_prompt(issue) do
    """
    The implementation is complete, but the Symphony work plan is out of date.

    Issue: #{issue.identifier} - #{issue.title}

    Update only `.git/symphony/plan.json` so it accurately reflects the work already completed in the workspace.

    Rules:
    - Do not make product code changes.
    - Mark completed steps as `completed`.
    - If any remaining work is actually unfinished, mark it `in_progress`, `pending`, or `blocked` truthfully.
    - Keep the existing step structure and text stable unless it is obviously wrong, but do correct the plan if reality diverged from it.
    - The file must remain valid JSON.
    """
  end

  def append_plan_context(prompt, workspace_path) do
    case load_plan_result(workspace_path) do
      {:ok, plan} ->
        prompt <>
          """

          Current execution plan:
          #{PlanContract.render_workpad(plan)}

          Plan contract:
          - Execute against the plan. Do not treat it as a one-time sketch.
          - `.git/symphony/plan.json` is the machine-editable plan, and Symphony mirrors it into Linear. The Linear plan comment is the authoritative shared view for humans.
          - Update `.git/symphony/plan.json` before you start a step, when you change the plan, and when you finish a step.
          - Keep exactly one currently active step marked `in_progress` while you are working on it, unless you are blocked.
          - If you add, remove, split, merge, or reorder work, update the plan first so the checklist stays truthful.
          - Update the status of every plan step so it reflects reality before you finish this turn.
          - If the work is complete, every plan step should be `completed`.
          - If you are blocked, mark the relevant step `blocked`.
          - Do not delete completed steps; keep the checklist stable and update statuses instead.
          """

      _ ->
        prompt
    end
  end

  def append_completion_prompt(prompt, config, workspace_path) do
    prompt <>
      """

      Completion contract:
      Before you finish a turn, write a valid JSON result file to `.git/symphony/result.json`.
      Symphony uses this file to decide whether the issue is complete, blocked, or needs another turn.

      Result file schema:
      {
        "status": "completed | needs_more_work | blocked",
        "summary": "Short summary of what happened this turn",
        "tests": ["Commands you ran to validate the work"],
        "artifacts": ["Optional human-readable artifact paths or links"],
        "notes": "Optional follow-up or blocker details"
      }

      Rules:
      - Use `completed` only when the task is actually ready for review handoff.
      - Use `needs_more_work` if you made progress but the issue still requires another implementation turn.
      - Use `blocked` if you cannot continue without clarification, credentials, external fixes, or other missing prerequisites.
      - The file must be valid JSON with double-quoted keys and strings.
      """
      |> append_demo_prompt(config, workspace_path)
  end

  def append_demo_prompt(prompt, config, workspace_path) when config.recording_enabled == true do
    recording_url = config.recording_url || "http://127.0.0.1:3000"
    demo_repo_context = AgentRunnerDemoContext.prompt(workspace_path)

    prompt <>
      """

      Demo recording requirement:
      If `.git/symphony/result.json` uses `"status": "completed"`, also write a valid JSON demo plan to `.git/symphony/demo-plan.json` that shows the finished feature in action.
      The recorder will execute this plan automatically, so make it the shortest sequence that proves the user-visible change.
      If there is no meaningful user-visible demo for this task, you may instead mark the plan as non-demoable with a short reason.
      Use this base URL for the demo unless a different path in the same app is needed: #{recording_url}

      Demo plan schema:
      {
        "capture": "video",
        "non_demoable": false,
        "reason": "Only required when non_demoable is true",
        "setup_command": "Optional command to start the local app needed for the demo",
        "teardown_command": "Optional command to stop or clean up the local app after capture",
        "ready_url": "Optional URL the recorder should wait for before opening the demo page",
        "url": "#{recording_url}/path",
        "wait_for_text": "Optional text expected before demo begins",
        "wait_for_selector": "Optional selector expected before demo begins",
        "settle_ms": 1500,
        "assertions": [
          {"type": "text_present", "value": "Expected UI text"},
          {"type": "selector_visible", "selector": "[data-demo='ready']"},
          {"type": "selector_hidden", "selector": "[data-demo='loading']"},
          {"type": "url_includes", "value": "/feature"},
          {"type": "title_includes", "value": "Feature"},
          {"type": "selector_text_equals", "selector": "[data-demo='status']", "value": "Live"},
          {"type": "attribute_equals", "selector": "link[rel='alternate']", "attribute": "type", "value": "application/rss+xml"},
          {"type": "selector_count_at_least", "selector": "article", "value": 2},
          {"type": "text_absent", "value": "404"},
          {"type": "console_errors_absent"}
        ],
        "steps": [
          {"action": "wait", "ms": 1000},
          {"action": "click", "selector": "a[href='/feature']"},
          {"action": "scroll", "y": 900},
          {"action": "wait_for_text", "text": "Expected UI text"},
          {"action": "wait_for_selector", "selector": "[data-demo='ready']"},
          {"action": "press", "key": "Enter"},
          {"action": "type", "selector": "input[name='q']", "text": "query"},
          {"action": "goto", "url": "http://127.0.0.1:3000/other"},
          {"action": "scroll_to_selector", "selector": "#result"}
        ]
      }

      Rules:
      - Choose `"capture": "video"` for motion or interaction: clicks, typing, scrolling, navigation, transitions, menus, dropdowns, or multi-step flows.
      - Choose `"capture": "screenshot"` by default for static visual proof: removed/added sections, spacing, typography, color, layout, icon, badge, copy, or a single final rendered state.
      - Only choose `"capture": "video"` when motion or interaction is actually necessary to prove the change.
      - If the demo needs a local app server or other local process, provide a deterministic `setup_command` and, when helpful, a `ready_url`.
      - Inspect the actual workspace before choosing `setup_command`, `ready_url`, or `url`. Use the repo's real framework/dev command and real port, not a generic guess.
      - If `url` or `ready_url` points at `127.0.0.1`, `localhost`, or another local dev URL, include a `setup_command` unless the issue explicitly says the app is already running externally.
      - Do not assume port `3000`. Choose a concrete host and port that matches the actual app you inspected, and include that same host/port consistently in `setup_command`, `ready_url`, and `url`.
      - Do not use a vague command like bare `npm run dev` when a local URL is involved. Prefer an explicit command that binds the expected host/port, such as adding `-- --host 127.0.0.1 --port <port>` when the framework supports it.
      - `setup_command` must work in a fresh workspace clone, but do not add `npm install`, `pnpm install`, or similar bootstrap by default. Only include dependency installation if you verified the workspace actually needs it for this demo.
      - Use `teardown_command` only when the setup needs explicit cleanup beyond normal process termination.
      - Choose steps based on the actual feature you implemented, not a generic homepage capture.
      - Include only actions needed to demonstrate the change clearly.
      - Prefer stable selectors or obvious links/buttons.
      - Demo assertions are only artifact sanity checks. They are not unit tests or integration tests.
      - For `"capture": "screenshot"`, use no assertions unless the recorder explicitly needs one trivial selector check to avoid a blank page.
      - For `"capture": "video"`, use at most 1 to 3 assertions.
      - Any assertions must only cover the requested visible change and the final on-screen state needed to prove it.
      - Do not add broad page sanity checks, unrelated content checks, or generic regression checks.
      - Assertions are evaluated after all steps finish, so they must describe only the final demo state.
      - If the task is backend-only or otherwise not meaningfully demoable, set `non_demoable` to true and explain why in `reason`.
      - The file must be valid JSON with double-quoted keys and strings.

      #{demo_repo_context}
      """
  end

  def append_demo_prompt(prompt, _config, _workspace_path), do: prompt

  def append_feedback_context(prompt, %Issue{feedback_assets_text: text})
      when is_binary(text) and text != "" do
    prompt <>
      """

      Additional feedback context:
      #{text}
      """
  end

  def append_feedback_context(prompt, _issue), do: prompt

  defp load_plan_result(workspace_path) do
    path = Path.join(workspace_path, ".git/symphony/plan.json")

    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_plan}
    end
  end
end
