defmodule Symphony.CodexRouter do
  @moduledoc "Heuristic model router for Codex turns."

  @complexity_keywords [
    "migration",
    "refactor",
    "distributed",
    "concurrency",
    "race condition",
    "performance",
    "security",
    "incident",
    "production",
    "schema",
    "protocol",
    "orchestrator",
    "backward compatibility"
  ]

  def route(issue, attempt, config, opts \\ []) do
    percentile = config.codex_router_hard_percentile || 95
    score = difficulty_score(issue)

    had_implementation_issues =
      Keyword.get(opts, :had_implementation_issues, false) or
        (is_integer(attempt) and attempt > 1)

    hard_task? = score >= percentile or had_implementation_issues
    provider =
      if hard_task? do
        config.codex_router_hard_provider || "codex"
      else
        config.codex_router_default_provider || "zai"
      end

    profile = provider_profile(config, provider)

    model =
      if hard_task? do
        config.codex_router_hard_model || profile[:model] || "codex-5-3"
      else
        config.codex_router_model || profile[:model] || config.codex_model || "GLM-5"
      end

    effort =
      if hard_task? do
        config.codex_router_hard_effort || "xhigh"
      else
        config.codex_reasoning_effort
      end

    %{
      provider: provider,
      model: model,
      model_provider: profile[:model_provider] || config.codex_model_provider,
      auth_mode: profile[:auth_mode],
      effort: effort,
      hard_task?: hard_task?,
      difficulty_score: score,
      reason:
        if(hard_task?,
          do: "hard_task_or_previous_issues",
          else: "default_router_model"
        )
    }
  end

  defp provider_profile(config, provider_name) do
    profiles = config.codex_profiles || %{}
    Map.get(profiles, provider_name, %{})
  end

  def difficulty_score(issue) do
    title = normalize_text(issue.title)
    description = normalize_text(issue.description)
    text = title <> "\n" <> description

    keyword_score =
      @complexity_keywords
      |> Enum.count(&String.contains?(text, &1))
      |> Kernel.*(6)
      |> min(30)

    length_score =
      text
      |> String.length()
      |> div(250)
      |> min(20)

    blocker_score =
      issue
      |> Map.get(:blocked_by, [])
      |> List.wrap()
      |> length()
      |> Kernel.*(10)
      |> min(25)

    label_score =
      issue
      |> Map.get(:labels, [])
      |> List.wrap()
      |> Enum.map(&normalize_text/1)
      |> Enum.count(fn label ->
        String.contains?(label, "urgent") or
          String.contains?(label, "critical") or
          String.contains?(label, "security") or
          String.contains?(label, "infra")
      end)
      |> Kernel.*(8)
      |> min(16)

    priority_score =
      case issue.priority do
        0 -> 9
        1 -> 7
        2 -> 4
        _ -> 0
      end

    score = keyword_score + length_score + blocker_score + label_score + priority_score
    max(0, min(100, score))
  end

  defp normalize_text(nil), do: ""

  defp normalize_text(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.trim()
  end

  defp normalize_text(value), do: value |> to_string() |> normalize_text()
end
