defmodule Symphony.Logger do
  @moduledoc false

  require Logger

  @truncate_chars Application.compile_env(:symphony, :logger_truncate_chars, 2000)

  def info(event, meta \\ []) do
    Logger.info(event, meta)
  end

  def warn(event, meta \\ []) do
    Logger.warning(event, meta)
  end

  def error(event, meta \\ []) do
    Logger.error(event, meta)
  end

  def debug(event, meta \\ []) do
    Logger.debug(event, meta)
  end

  defp truncate_binary(str) when is_binary(str) do
    if String.length(str) > @truncate_chars do
      String.slice(str, 0, @truncate_chars) <> "..."
    else
      str
    end
  end

  def truncate(value) when is_binary(value), do: truncate_binary(value)
  def truncate(value), do: inspect(value)
end
