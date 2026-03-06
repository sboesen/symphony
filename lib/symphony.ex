defmodule Symphony do
  @moduledoc "Root module for the Symphony service."

  def start(_type, args), do: Symphony.CLI.main(args)
end
