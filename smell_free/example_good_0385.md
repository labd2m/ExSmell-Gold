```elixir
defmodule MyApp.Config do
  @moduledoc """
  Centralises runtime configuration loading and validation. All required
  environment variables are declared explicitly so the application fails
  fast at startup with a descriptive message when configuration is missing,
  rather than crashing later during a live request with an obscure error.

  Configuration is loaded once and cached in module attributes for
  zero-overhead access in hot paths. Sensitive values are never logged.
  """

  require Logger

  @type database_config :: %{
          url: binary(),
          pool_size: pos_integer(),
          ssl: boolean()
        }

  @type smtp_config :: %{
          host: binary(),
          port: pos_integer(),
          username: binary(),
          password: binary()
        }

  @doc """
  Validates and loads all required configuration. Raises `RuntimeError`
  with a clear summary of every missing or invalid variable. Call once
  from `Application.start/2` before starting any supervised children.
  """
  @spec load!() :: :ok
  def load! do
    errors = collect_errors()

    if errors == [] do
      Logger.info("Configuration validated successfully")
      :ok
    else
      message = format_errors(errors)
      raise RuntimeError, message
    end
  end

  @doc """
  Returns the validated database configuration map.
  """
  @spec database() :: database_config()
  def database do
    %{
      url: fetch!("DATABASE_URL"),
      pool_size: fetch_integer!("DATABASE_POOL_SIZE", default: 10),
      ssl: fetch_boolean("DATABASE_SSL", default: true)
    }
  end

  @doc """
  Returns the validated SMTP configuration map.
  """
  @spec smtp() :: smtp_config()
  def smtp do
    %{
      host: fetch!("SMTP_HOST"),
      port: fetch_integer!("SMTP_PORT", default: 587),
      username: fetch!("SMTP_USERNAME"),
      password: fetch!("SMTP_PASSWORD")
    }
  end

  @doc """
  Returns the secret key base used for token signing.
  Raises when the value is absent or shorter than 64 bytes.
  """
  @spec secret_key_base!() :: binary()
  def secret_key_base! do
    value = fetch!("SECRET_KEY_BASE")

    if byte_size(value) < 64 do
      raise RuntimeError, "SECRET_KEY_BASE must be at least 64 bytes"
    end

    value
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp collect_errors do
    required = ~w[DATABASE_URL SECRET_KEY_BASE SMTP_HOST SMTP_USERNAME SMTP_PASSWORD]

    Enum.flat_map(required, fn var ->
      case System.get_env(var) do
        nil -> ["#{var} is required but not set"]
        "" -> ["#{var} is set but empty"]
        _ -> []
      end
    end)
  end

  defp format_errors(errors) do
    list = Enum.map_join(errors, "\n  - ", & &1)
    "\n\nConfiguration errors:\n  - #{list}\n"
  end

  defp fetch!(var) do
    System.fetch_env!(var)
  end

  defp fetch_integer!(var, opts) do
    default = Keyword.get(opts, :default)

    case System.get_env(var) do
      nil when not is_nil(default) ->
        default

      nil ->
        raise RuntimeError, "#{var} is required but not set"

      raw ->
        case Integer.parse(raw) do
          {value, ""} -> value
          _ -> raise RuntimeError, "#{var} must be an integer, got: #{raw}"
        end
    end
  end

  defp fetch_boolean(var, opts) do
    default = Keyword.get(opts, :default, false)

    case System.get_env(var) do
      nil -> default
      "true" -> true
      "1" -> true
      "false" -> false
      "0" -> false
      raw -> raise RuntimeError, "#{var} must be true/false, got: #{raw}"
    end
  end
end
```
