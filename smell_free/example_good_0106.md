```elixir
defmodule Config.Provider do
  @moduledoc """
  Runtime configuration provider for external services. Reads values from
  environment variables at boot time and exposes them through a typed
  structured API. Raises at startup when required variables are absent so
  that misconfigured deployments fail immediately and loudly rather than
  at first use.
  """

  @enforce_keys [:database_url, :redis_url, :s3_bucket, :sendgrid_api_key]
  defstruct [
    :database_url,
    :redis_url,
    :s3_bucket,
    :sendgrid_api_key,
    pool_size: 10,
    request_timeout_ms: 15_000,
    log_level: :info
  ]

  @type t :: %__MODULE__{
          database_url: String.t(),
          redis_url: String.t(),
          s3_bucket: String.t(),
          sendgrid_api_key: String.t(),
          pool_size: pos_integer(),
          request_timeout_ms: pos_integer(),
          log_level: :debug | :info | :warning | :error
        }

  @required_vars ~w(DATABASE_URL REDIS_URL S3_BUCKET SENDGRID_API_KEY)
  @valid_log_levels ~w(debug info warning error)

  @doc """
  Loads all configuration from environment variables. Raises `RuntimeError`
  when required variables are missing so startup fails fast.
  """
  @spec load!() :: t()
  def load! do
    validate_required!()

    %__MODULE__{
      database_url: System.fetch_env!("DATABASE_URL"),
      redis_url: System.fetch_env!("REDIS_URL"),
      s3_bucket: System.fetch_env!("S3_BUCKET"),
      sendgrid_api_key: System.fetch_env!("SENDGRID_API_KEY"),
      pool_size: parse_integer("POOL_SIZE", 10),
      request_timeout_ms: parse_integer("REQUEST_TIMEOUT_MS", 15_000),
      log_level: parse_log_level("LOG_LEVEL", :info)
    }
  end

  @doc "Returns the database pool size for the given environment."
  @spec pool_size_for_env(t(), :prod | :dev | :test) :: pos_integer()
  def pool_size_for_env(%__MODULE__{pool_size: size}, :prod), do: size
  def pool_size_for_env(%__MODULE__{}, :dev), do: 5
  def pool_size_for_env(%__MODULE__{}, :test), do: 2

  @doc "Returns true when the given feature flag is enabled via environment variable."
  @spec feature_enabled?(String.t()) :: boolean()
  def feature_enabled?(flag_name) when is_binary(flag_name) do
    var = "FEATURE_#{String.upcase(flag_name)}"
    System.get_env(var, "false") in ~w(1 true yes enabled)
  end

  defp validate_required! do
    missing = Enum.reject(@required_vars, &System.get_env(&1))

    unless Enum.empty?(missing) do
      raise RuntimeError,
            "Missing required environment variables: #{Enum.join(missing, ", ")}"
    end
  end

  defp parse_integer(var, default) do
    case System.get_env(var) do
      nil -> default
      raw -> parse_positive_integer(raw, default)
    end
  end

  defp parse_positive_integer(raw, default) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_log_level(var, default) do
    raw = System.get_env(var, Atom.to_string(default))

    if raw in @valid_log_levels do
      String.to_existing_atom(raw)
    else
      default
    end
  end
end
```
