defmodule Symphony.OpenCodeRuntime do
  @moduledoc "Builds an isolated OpenCode runtime environment for Symphony-managed turns."

  @config_dirname ".symphony-opencode"

  def build_env(workspace_path, base_env, opts \\ %{}) do
    config_home = ensure_config_home(workspace_path)

    base_env
    |> Map.put("XDG_CONFIG_HOME", config_home)
    |> Map.put("OPENCODE_CONFIG_CONTENT", Jason.encode!(runtime_config(opts)))
  end

  def runtime_config(opts \\ %{}) do
    permission =
      opts
      |> Map.get(:permission, %{
        "edit" => "allow",
        "bash" => "allow",
        "webfetch" => "allow",
        "external_directory" => "allow"
      })

    config =
      %{
        "mcp" => %{},
        "permission" => permission
      }
      |> maybe_put("provider", provider_config(opts))
      |> maybe_put("model", opts[:model])
      |> maybe_put("small_model", opts[:small_model])

    config
  end

  defp provider_config(opts) do
    provider_id = opts[:provider_id]
    api_key = normalize_string(opts[:api_key])
    base_url = normalize_string(opts[:base_url])

    cond do
      is_nil(provider_id) or provider_id == "" ->
        nil

      is_nil(api_key) and is_nil(base_url) ->
        nil

      true ->
        options =
          %{}
          |> maybe_put("apiKey", api_key)
          |> maybe_put("baseURL", base_url)

        %{provider_id => %{"options" => options}}
    end
  end

  defp ensure_config_home(workspace_path) do
    path = Path.join(workspace_path, @config_dirname)
    File.mkdir_p!(Path.join(path, "opencode"))
    path
  end

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_), do: nil

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value) when is_binary(value) do
    normalized = String.trim(value)
    if normalized == "", do: map, else: Map.put(map, key, normalized)
  end

  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
