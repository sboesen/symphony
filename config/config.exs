import Config

config :symphony,
  logger_truncate_chars: 2000

config :symphony, Symphony.Application,
  workflow_path: nil

# Finch is used for linear API calls.
config :symphony, :finch_name, Symphony.Finch

import_config "#{config_env()}.exs"
