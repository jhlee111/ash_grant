import Config

config :ash, :disable_async?, true

# Ash requires this to be set explicitly (it raises a DslError at compile time
# otherwise). `:codepoints` counts the way SQL data layers do, so `max_length`
# means the same thing in validation and in the database.
config :ash, default_string_length_count: :codepoints

import_config "#{config_env()}.exs"
