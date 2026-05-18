```elixir
defmodule Config.Loader do
  @moduledoc """
  Loads, merges, and validates layered application configuration from
  environment variables, config files, and runtime overrides. Supports
  deep merging so that nested config keys are overlaid rather than replaced.
  """

  @defaults %{
    server: %{port: 4000, host: "0.0.0.0", timeout_ms: 30_000},
    database: %{pool_size: 10, timeout: 15_000, ssl: false},
    cache: %{ttl: 300, max_entries: 10_000},
    logging: %{level: :info, format: :json}
  }


  def load(env \\ Mix.env()) do
    require Config.Loader

    file_config   = load_from_file(env)
    env_config    = load_from_env()

    @defaults
    |> Config.Loader.deep_merge(file_config)
    |> Config.Loader.deep_merge(env_config)
  end

  def load_with_overrides(overrides) do
    require Config.Loader

    base = load()
    Config.Loader.deep_merge(base, overrides)
  end

  def validate(config) do
    errors =
      []
      |> check_port(config)
      |> check_pool_size(config)
      |> check_log_level(config)

    if errors == [], do: {:ok, config}, else: {:error, errors}
  end

  defp check_port(errors, %{server: %{port: port}})
       when is_integer(port) and port > 0 and port < 65_536,
       do: errors

  defp check_port(errors, _), do: ["Invalid server port" | errors]

  defp check_pool_size(errors, %{database: %{pool_size: size}})
       when is_integer(size) and size > 0,
       do: errors

  defp check_pool_size(errors, _), do: ["Invalid database pool_size" | errors]

  defp check_log_level(errors, %{logging: %{level: level}})
       when level in [:debug, :info, :warning, :error],
       do: errors

  defp check_log_level(errors, _), do: ["Invalid log level" | errors]

  defp load_from_file(env) do
    path = "config/#{env}.exs"

    if File.exists?(path) do
      {config, _} = Code.eval_file(path)
      if is_map(config), do: config, else: %{}
    else
      %{}
    end
  end

  defp load_from_env do
    %{
      server: %{
        port: parse_int(System.get_env("PORT"), nil),
        host: System.get_env("HOST")
      },
      database: %{
        pool_size: parse_int(System.get_env("DB_POOL_SIZE"), nil),
        ssl: System.get_env("DB_SSL") == "true"
      },
      logging: %{
        level: parse_log_level(System.get_env("LOG_LEVEL"))
      }
    }
    |> deep_remove_nils()
  end

  defp deep_remove_nils(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {k, if(is_map(v), do: deep_remove_nils(v), else: v)} end)
    |> Map.new()
  end

  defp parse_int(nil, default), do: default
  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, ""} -> n
      _       -> default
    end
  end

  defp parse_log_level("debug"),   do: :debug
  defp parse_log_level("info"),    do: :info
  defp parse_log_level("warning"), do: :warning
  defp parse_log_level("error"),   do: :error
  defp parse_log_level(_),         do: nil
end
```
