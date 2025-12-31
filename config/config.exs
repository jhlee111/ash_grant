import Config

config :ash, :disable_async?, true

import_config "#{config_env()}.exs"
