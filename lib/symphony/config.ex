defmodule Symphony.Config do
  @moduledoc "Typed runtime config derived from workflow front matter."

  @zai_base_url "https://api.z.ai/api/coding/paas/v4"

  defstruct [
    :tracker_kind,
    :tracker_endpoint,
    :tracker_api_key,
    :tracker_project_slug,
    :tracker_mock_file,
    :tracker_active_states,
    :tracker_terminal_states,
    :poll_interval_ms,
    :workspace_root,
    :hooks_after_create,
    :hooks_before_run,
    :hooks_after_run,
    :hooks_before_remove,
    :hooks_timeout_ms,
    :max_concurrent_agents,
    :max_retry_backoff_ms,
    :max_concurrent_agents_by_state,
    :codex_command,
    :openai_api_key,
    :zai_api_key,
    :openai_base_url,
    :codex_model,
    :codex_model_provider,
    :codex_reasoning_effort,
    :codex_profiles,
    :codex_router_enabled,
    :codex_router_default_provider,
    :codex_router_hard_provider,
    :codex_router_model,
    :codex_router_hard_model,
    :codex_router_hard_effort,
    :codex_router_hard_percentile,
    :approval_policy,
    :thread_sandbox,
    :turn_sandbox_policy,
    :turn_timeout_ms,
    :read_timeout_ms,
    :stall_timeout_ms,
    :max_turns,
    :server_port,
    :recording_enabled,
    :recording_url,
    :recording_ready_url,
    :recording_setup_command,
    :recording_teardown_command,
    :recording_wait_for_selector,
    :recording_wait_for_text,
    :recording_output_dir,
    :recording_wait_ms,
    :recording_ready_timeout_ms,
    :recording_width,
    :recording_height,
    :recording_trace,
    :recording_strict,
    :recording_publish_to_tracker,
    :recording_publish_comment,
    :review_pr_enabled,
    :review_pr_draft,
    :review_pr_base_branch,
    :review_pr_auto_merge,
    :github_webhook_secret,
    :github_webhook_auto_register,
    :github_webhook_provider,
    :github_webhook_repo
  ]

  def from_workflow(%Symphony.Workflow{config: config}) when is_map(config) do
    cfg = fn path -> get_in(config, path) end
    router = cfg.(["codex", "router"]) || %{}

    openai_api_key =
      resolve_env(cfg.(["codex", "api_key"])) ||
        resolve_env(cfg.(["codex", "openai_api_key"])) ||
        System.get_env("OPENAI_API_KEY")

    zai_api_key =
      resolve_env(cfg.(["codex", "zai_api_key"])) ||
        resolve_env(cfg.(["codex", "z_api_key"])) ||
        System.get_env("Z_API_KEY")

    github_webhook_secret =
      resolve_env(cfg.(["github", "webhook", "secret"])) ||
        System.get_env("GITHUB_WEBHOOK_SECRET")

    github_webhook_provider =
      resolve_env(cfg.(["github", "webhook", "provider"])) || "ngrok"

    github_webhook_repo =
      resolve_env(cfg.(["github", "webhook", "repo"])) ||
        github_repo_slug(System.get_env("GITHUB_REPO_URL"))

    github_webhook_auto_register =
      resolve_bool(
        cfg.(["github", "webhook", "auto_register"]) ||
          System.get_env("SYMPHONY_GITHUB_WEBHOOK_AUTO_REGISTER"),
        default_github_webhook_auto_register(
          github_webhook_secret,
          github_webhook_repo,
          github_webhook_provider
        )
      )

    openai_base_url =
      resolve_url(
        cfg.(["codex", "openai_base_url"]) || System.get_env("OPENAI_BASE_URL"),
        @zai_base_url
      )

    codex_model = resolve_env(cfg.(["codex", "model"])) || System.get_env("OPENAI_MODEL")

    codex_model_provider =
      resolve_env(cfg.(["codex", "model_provider"])) || System.get_env("OPENAI_MODEL_PROVIDER")

    codex_profiles =
      build_provider_profiles(
        cfg.(["codex", "providers"]),
        openai_api_key,
        zai_api_key,
        openai_base_url,
        codex_model_provider,
        codex_model
      )

    parsed = %__MODULE__{
      tracker_kind: cfg.(["tracker", "kind"]) || "linear",
      tracker_endpoint: cfg.(["tracker", "endpoint"]) || "https://api.linear.app/graphql",
      tracker_api_key:
        resolve_env(cfg.(["tracker", "api_key"])) || System.get_env("LINEAR_API_KEY"),
      tracker_project_slug:
        resolve_env(cfg.(["tracker", "project_slug"])) || System.get_env("LINEAR_PROJECT_SLUG"),
      tracker_mock_file:
        resolve_env(cfg.(["tracker", "mock_file"]) || cfg.(["tracker", "mock", "file"])),
      tracker_active_states:
        normalize_state_list(
          resolve_list(cfg.(["tracker", "active_states"]), ["Todo", "In Progress"])
        ),
      tracker_terminal_states:
        normalize_state_list(
          resolve_list(cfg.(["tracker", "terminal_states"]), [
            "Closed",
            "Cancelled",
            "Canceled",
            "Duplicate",
            "Done"
          ])
        ),
      poll_interval_ms: resolve_int(cfg.(["polling", "interval_ms"]), 30_000),
      workspace_root: resolve_workspace_root(cfg.(["workspace", "root"])),
      hooks_after_create: cfg.(["hooks", "after_create"]),
      hooks_before_run: cfg.(["hooks", "before_run"]),
      hooks_after_run: cfg.(["hooks", "after_run"]),
      hooks_before_remove: cfg.(["hooks", "before_remove"]),
      hooks_timeout_ms: positive_int(resolve_int(cfg.(["hooks", "timeout_ms"]), 60_000), 60_000),
      max_concurrent_agents: resolve_int(cfg.(["agent", "max_concurrent_agents"]), 10),
      max_retry_backoff_ms: resolve_int(cfg.(["agent", "max_retry_backoff_ms"]), 300_000),
      max_concurrent_agents_by_state:
        normalize_map(cfg.(["agent", "max_concurrent_agents_by_state"]) || %{}),
      codex_command: cfg.(["codex", "command"]) || "codex app-server",
      openai_api_key: openai_api_key,
      zai_api_key: zai_api_key,
      openai_base_url: openai_base_url,
      codex_model: codex_model,
      codex_model_provider: codex_model_provider,
      codex_reasoning_effort: resolve_env(cfg.(["codex", "reasoning_effort"])),
      codex_profiles: codex_profiles,
      codex_router_enabled: resolve_bool(router["enabled"] || router[:enabled], true),
      codex_router_default_provider:
        resolve_env(router["default_provider"] || router[:default_provider]) || "zai",
      codex_router_hard_provider:
        resolve_env(router["hard_provider"] || router[:hard_provider]) || "codex",
      codex_router_model:
        resolve_env(router["default_model"] || router[:default_model]) ||
          resolve_env(cfg.(["codex", "model"])) ||
          "GLM-5",
      codex_router_hard_model:
        resolve_env(router["hard_model"] || router[:hard_model]) ||
          "codex-5-3",
      codex_router_hard_effort:
        resolve_env(router["hard_effort"] || router[:hard_effort]) ||
          "xhigh",
      codex_router_hard_percentile:
        clamp(resolve_int(router["hard_percentile"] || router[:hard_percentile], 95), 50, 99),
      approval_policy: cfg.(["codex", "approval_policy"]),
      thread_sandbox: cfg.(["codex", "thread_sandbox"]),
      turn_sandbox_policy: cfg.(["codex", "turn_sandbox_policy"]),
      turn_timeout_ms: resolve_int(cfg.(["codex", "turn_timeout_ms"]), 3_600_000),
      read_timeout_ms: resolve_int(cfg.(["codex", "read_timeout_ms"]), 5_000),
      stall_timeout_ms: resolve_int(cfg.(["codex", "stall_timeout_ms"]), 300_000),
      max_turns: resolve_int(cfg.(["agent", "max_turns"]), 20),
      server_port:
        resolve_server_port(
          System.get_env("SYMPHONY_SERVER_PORT") ||
            cfg.(["server", "port"]) ||
            System.get_env("PORT")
        ),
      recording_enabled: resolve_bool(cfg.(["recording", "enabled"]), false),
      recording_url: resolve_text(cfg.(["recording", "url"])),
      recording_ready_url: resolve_text(cfg.(["recording", "ready_url"])),
      recording_setup_command: resolve_script(cfg.(["recording", "setup_command"])),
      recording_teardown_command: resolve_script(cfg.(["recording", "teardown_command"])),
      recording_wait_for_selector: resolve_text(cfg.(["recording", "wait_for_selector"])),
      recording_wait_for_text: resolve_text(cfg.(["recording", "wait_for_text"])),
      recording_output_dir:
        resolve_text(cfg.(["recording", "output_dir"])) || ".symphony/artifacts/recordings",
      recording_wait_ms: positive_int(resolve_int(cfg.(["recording", "wait_ms"]), 2_000), 2_000),
      recording_ready_timeout_ms:
        positive_int(resolve_int(cfg.(["recording", "ready_timeout_ms"]), 30_000), 30_000),
      recording_width: positive_int(resolve_int(cfg.(["recording", "width"]), 1440), 1440),
      recording_height: positive_int(resolve_int(cfg.(["recording", "height"]), 900), 900),
      recording_trace: resolve_bool(cfg.(["recording", "trace"]), true),
      recording_strict: resolve_bool(cfg.(["recording", "strict"]), false),
      recording_publish_to_tracker:
        resolve_bool(cfg.(["recording", "publish_to_tracker"]), true),
      recording_publish_comment:
        resolve_bool(cfg.(["recording", "publish_comment"]), true),
      review_pr_enabled: resolve_bool(cfg.(["review", "pr", "enabled"]), true),
      review_pr_draft: resolve_bool(cfg.(["review", "pr", "draft"]), false),
      review_pr_base_branch: resolve_text(cfg.(["review", "pr", "base_branch"])),
      review_pr_auto_merge: resolve_bool(cfg.(["review", "pr", "auto_merge"]), true),
      github_webhook_secret: github_webhook_secret,
      github_webhook_auto_register: github_webhook_auto_register,
      github_webhook_provider: github_webhook_provider,
      github_webhook_repo: github_webhook_repo
    }

    parsed =
      parsed
      |> Map.update!(:max_turns, fn value ->
        if is_integer(value) and value > 0, do: value, else: 20
      end)
      |> Map.update!(:max_concurrent_agents, fn value ->
        if is_integer(value) and value > 0, do: value, else: 10
      end)
      |> Map.update!(:poll_interval_ms, fn value ->
        if is_integer(value) and value > 0, do: value, else: 30_000
      end)

    {:ok, %{parsed | workspace_root: parsed.workspace_root || default_workspace_root()}}
  end

  def validate_dispatch(%__MODULE__{} = cfg) do
    unsupported_backend? =
      Enum.any?(cfg.codex_profiles || %{}, fn {_name, profile} ->
        backend = profile[:backend]
        not is_nil(backend) and backend not in Symphony.Runner.supported_backends()
      end)

    cond do
      cfg.tracker_kind not in ["linear", "mock"] ->
        {:error, :unsupported_tracker}

      cfg.tracker_kind == "linear" and
          (is_nil(cfg.tracker_api_key) or String.trim(cfg.tracker_api_key) == "") ->
        {:error, :tracker_api_key_missing}

      cfg.tracker_kind == "linear" and
          (is_nil(cfg.tracker_project_slug) or String.trim(cfg.tracker_project_slug) == "") ->
        {:error, :tracker_project_slug_missing}

      cfg.tracker_kind == "mock" and
          (is_nil(cfg.tracker_mock_file) or String.trim(cfg.tracker_mock_file) == "") ->
        {:error, :tracker_mock_file_missing}

      cfg.max_concurrent_agents <= 0 ->
        {:error, :invalid_max_concurrent_agents}

      cfg.poll_interval_ms <= 0 ->
        {:error, :invalid_poll_interval}

      is_nil(cfg.codex_command) or String.trim(cfg.codex_command) == "" ->
        {:error, :codex_command_missing}

      cfg.recording_enabled and
          (is_nil(cfg.recording_url) or String.trim(cfg.recording_url) == "") ->
        {:error, :recording_url_missing}

      unsupported_backend? ->
        {:error, :unsupported_codex_backend}

      true ->
        :ok
    end
  end

  defp build_provider_profiles(
         raw_providers,
         openai_api_key,
         zai_api_key,
         zai_base_url,
         model_provider,
         model
       ) do
    defaults = %{
      "zai" => %{
        name: "zai",
        api_key: zai_api_key || openai_api_key,
        z_api_key: zai_api_key,
        base_url: zai_base_url,
        model_provider: model_provider,
        model: "GLM-5",
        auth_mode: "api_key",
        backend: "opencode",
        command: System.get_env("SYMPHONY_OPENCODE_COMMAND") || "opencode",
        env: %{}
      },
      "codex" => %{
        name: "codex",
        api_key: nil,
        z_api_key: nil,
        base_url: nil,
        model_provider: model_provider,
        model: model || "codex-5-3",
        auth_mode: "app_server",
        backend: "codex_app_server",
        command: System.get_env("SYMPHONY_CODEX_COMMAND") || "codex app-server",
        env: %{}
      }
    }

    custom =
      if is_map(raw_providers) do
        Enum.reduce(raw_providers, %{}, fn {name, value}, acc ->
          profile_name = to_string(name)

          if is_map(value) do
            Map.put(acc, profile_name, normalize_provider_profile(profile_name, value))
          else
            acc
          end
        end)
      else
        %{}
      end

    Enum.reduce(custom, defaults, fn {name, profile}, acc ->
      base = Map.get(acc, name, %{name: name, env: %{}})

      merged =
        base
        |> merge_non_nil(profile)
        |> Map.update(:env, %{}, fn env ->
          base_env = Map.get(base, :env, %{})
          Map.merge(base_env, env || %{})
        end)

      Map.put(acc, name, merged)
    end)
  end

  defp normalize_provider_profile(name, value) do
    %{
      name: name,
      api_key:
        resolve_env(
          value["api_key"] || value[:api_key] ||
            value["openai_api_key"] || value[:openai_api_key]
        ),
      z_api_key:
        resolve_env(
          value["z_api_key"] || value[:z_api_key] ||
            value["zai_api_key"] || value[:zai_api_key]
        ),
      base_url:
        resolve_url(
          value["base_url"] || value[:base_url] ||
            value["openai_base_url"] || value[:openai_base_url],
          nil
        ),
      model_provider: resolve_env(value["model_provider"] || value[:model_provider]),
      model: resolve_env(value["model"] || value[:model]),
      auth_mode:
        normalize_auth_mode(
          resolve_env(value["auth_mode"] || value[:auth_mode] || value["auth"] || value[:auth])
        ),
      backend:
        normalize_backend(
          resolve_env(value["backend"] || value[:backend] || value["runner"] || value[:runner])
        ),
      command: resolve_env(value["command"] || value[:command]),
      env: normalize_env_map(value["env"] || value[:env])
    }
  end

  defp normalize_env_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      env_key = key |> to_string() |> String.trim()
      env_val = resolve_env(value)

      if env_key == "" or is_nil(env_val) do
        acc
      else
        Map.put(acc, env_key, env_val)
      end
    end)
  end

  defp normalize_env_map(_), do: %{}

  defp normalize_auth_mode(nil), do: nil
  defp normalize_auth_mode("api_key"), do: "api_key"
  defp normalize_auth_mode("app_server"), do: "app_server"
  defp normalize_auth_mode("chatgpt_login"), do: "app_server"
  defp normalize_auth_mode(_), do: nil

  defp normalize_backend(nil), do: nil
  defp normalize_backend("opencode"), do: "opencode"
  defp normalize_backend("opencode_server"), do: "opencode_server"
  defp normalize_backend("open_code_server"), do: "opencode_server"
  defp normalize_backend("open_code"), do: "opencode"
  defp normalize_backend("codex"), do: "codex_app_server"
  defp normalize_backend("codex_app_server"), do: "codex_app_server"
  defp normalize_backend("app_server"), do: "codex_app_server"

  defp normalize_backend(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> normalize_backend()
  end

  defp normalize_backend(_), do: nil

  defp merge_non_nil(base, incoming) do
    Enum.reduce(incoming, base, fn {key, value}, acc ->
      if is_nil(value) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp resolve_env(nil), do: nil

  defp resolve_env(value) when is_binary(value) do
    if String.match?(value, ~r/^\$[A-Za-z_][A-Za-z0-9_]*$/) do
      System.get_env(String.trim_leading(value, "$"))
    else
      normalized = String.trim(value)
      if normalized == "", do: nil, else: normalized
    end
  end

  defp resolve_env(value) when is_atom(value), do: value |> Atom.to_string() |> resolve_env()
  defp resolve_env(value) when is_integer(value), do: Integer.to_string(value)
  defp resolve_env(_), do: nil

  defp resolve_int(nil, fallback), do: fallback
  defp resolve_int(v, _fallback) when is_integer(v), do: v

  defp resolve_int(v, fallback) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, _} -> n
      _ -> fallback
    end
  end

  defp resolve_int(_, fallback), do: fallback

  defp resolve_server_port(value) do
    case resolve_int(value, nil) do
      port when is_integer(port) and port > 0 ->
        port

      _ ->
        pick_available_port()
    end
  end

  defp pick_available_port do
    case :gen_tcp.listen(0, [:binary, {:packet, 0}, {:active, false}, {:reuseaddr, true}]) do
      {:ok, socket} ->
        port =
          case :inet.sockname(socket) do
            {:ok, {_addr, chosen_port}} when is_integer(chosen_port) and chosen_port > 0 ->
              chosen_port

            _ ->
              4012
          end

        _ = :gen_tcp.close(socket)
        port

      {:error, _} ->
        4012
    end
  end

  defp resolve_bool(nil, fallback), do: fallback
  defp resolve_bool(v, _fallback) when is_boolean(v), do: v

  defp resolve_bool(v, fallback) when is_binary(v) do
    case String.downcase(String.trim(v)) do
      "true" -> true
      "1" -> true
      "yes" -> true
      "false" -> false
      "0" -> false
      "no" -> false
      _ -> fallback
    end
  end

  defp resolve_bool(_, fallback), do: fallback

  defp default_github_webhook_auto_register(secret, repo, "ngrok")
       when is_binary(secret) and secret != "" and is_binary(repo) and repo != "" do
    not is_nil(System.find_executable("ngrok"))
  end

  defp default_github_webhook_auto_register(_secret, _repo, _provider), do: false

  defp positive_int(v, fallback), do: if(is_integer(v) and v > 0, do: v, else: fallback)

  defp resolve_url(nil, fallback), do: fallback

  defp resolve_url(value, fallback) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: fallback, else: normalized
  end

  defp resolve_url(_, fallback), do: fallback

  defp resolve_text(nil), do: nil

  defp resolve_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> expand_env(trimmed)
    end
  end

  defp resolve_text(value) when is_atom(value), do: value |> Atom.to_string() |> resolve_text()

  defp resolve_text(value) when is_integer(value),
    do: value |> Integer.to_string() |> resolve_text()

  defp resolve_text(_), do: nil

  defp resolve_script(nil), do: nil

  defp resolve_script(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed ->
        case resolve_env(trimmed) do
          nil -> trimmed
          resolved -> resolved
        end
    end
  end

  defp resolve_script(value) when is_atom(value),
    do: value |> Atom.to_string() |> resolve_script()

  defp resolve_script(value) when is_integer(value),
    do: value |> Integer.to_string() |> resolve_script()

  defp resolve_script(_), do: nil

  defp resolve_list(nil, fallback), do: fallback

  defp resolve_list(value, fallback) when is_binary(value) do
    parsed =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if parsed == [], do: fallback, else: parsed
  end

  defp resolve_list(value, _fallback) when is_list(value), do: value
  defp resolve_list(_, fallback), do: fallback

  defp normalize_state_list(states) when is_list(states) do
    states
    |> Enum.map(&Symphony.Issue.normalize_state/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp normalize_map(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {state, limit}, acc ->
      normalized = Symphony.Issue.normalize_state(state)
      parsed = resolve_int(limit, nil)

      if is_binary(normalized) and is_integer(parsed) and parsed > 0 do
        Map.put(acc, normalized, parsed)
      else
        acc
      end
    end)
  end

  defp normalize_map(_), do: %{}

  defp github_repo_slug(nil), do: nil

  defp github_repo_slug(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.replace_suffix(".git", "")

    cond do
      Regex.match?(~r{^https://github\.com/[^/]+/[^/]+$}, normalized) ->
        [_, owner, repo] = Regex.run(~r{^https://github\.com/([^/]+)/([^/]+)$}, normalized)
        "#{owner}/#{repo}"

      Regex.match?(~r{^git@github\.com:[^/]+/[^/]+$}, normalized) ->
        [_, owner, repo] = Regex.run(~r{^git@github\.com:([^/]+)/([^/]+)$}, normalized)
        "#{owner}/#{repo}"

      true ->
        nil
    end
  end

  defp resolve_workspace_root(nil), do: default_workspace_root()

  defp resolve_workspace_root(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        default_workspace_root()

      String.contains?(trimmed, "/") or String.contains?(trimmed, "\\") or
          String.starts_with?(trimmed, "~") ->
        expand_env(trimmed) |> Path.expand()

      true ->
        expand_env(trimmed)
    end
  end

  defp resolve_workspace_root(_), do: default_workspace_root()

  defp expand_env(value) do
    Regex.replace(~r/\$([A-Za-z_][A-Za-z0-9_]*)/, value, fn _, var ->
      System.get_env(var) || ""
    end)
  end

  defp clamp(v, min_v, _max_v) when v < min_v, do: min_v
  defp clamp(v, _min_v, max_v) when v > max_v, do: max_v
  defp clamp(v, _min_v, _max_v), do: v

  defp default_workspace_root do
    Path.join(System.tmp_dir!(), "symphony_workspaces")
  end
end
