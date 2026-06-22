```elixir
defmodule Config.SchemaLoader do
  @moduledoc """
  Loads, validates, and provides typed access to application configuration
  using a NimbleOptions schema. Surfaces actionable error messages for
  misconfigured values at application startup rather than at call sites.
  """

  @schema NimbleOptions.new!(
            database_url: [
              type: :string,
              required: true,
              doc: "PostgreSQL connection URL"
            ],
            pool_size: [
              type: :pos_integer,
              default: 10,
              doc: "Database connection pool size"
            ],
            redis_url: [
              type: :string,
              required: false,
              default: nil,
              doc: "Redis connection URL for caching"
            ],
            secret_key_base: [
              type: :string,
              required: true,
              doc: "Phoenix secret key base, minimum 64 bytes"
            ],
            max_upload_size_mb: [
              type: :pos_integer,
              default: 20,
              doc: "Maximum upload size in megabytes"
            ],
            allowed_origins: [
              type: {:list, :string},
              default: [],
              doc: "CORS allowed origin URLs"
            ],
            feature_flags: [
              type: :keyword_list,
              default: [],
              doc: "Compile-time feature flag overrides"
            ]
          )

  @type validated_config :: %{
          database_url: String.t(),
          pool_size: pos_integer(),
          redis_url: String.t() | nil,
          secret_key_base: String.t(),
          max_upload_size_mb: pos_integer(),
          allowed_origins: [String.t()],
          feature_flags: keyword()
        }

  @spec load!(keyword()) :: validated_config()
  def load!(raw_opts) when is_list(raw_opts) do
    case NimbleOptions.validate(raw_opts, @schema) do
      {:ok, validated} ->
        validated
        |> Map.new()
        |> validate_secret_key_base!()

      {:error, %NimbleOptions.ValidationError{message: msg}} ->
        raise ArgumentError, "Configuration error: #{msg}"
    end
  end

  @spec load(keyword()) :: {:ok, validated_config()} | {:error, String.t()}
  def load(raw_opts) when is_list(raw_opts) do
    case NimbleOptions.validate(raw_opts, @schema) do
      {:ok, validated} ->
        config = Map.new(validated)

        case validate_secret_key_base(config) do
          :ok -> {:ok, config}
          {:error, reason} -> {:error, reason}
        end

      {:error, %NimbleOptions.ValidationError{message: msg}} ->
        {:error, "Configuration error: #{msg}"}
    end
  end

  @spec from_env(atom()) :: {:ok, validated_config()} | {:error, String.t()}
  def from_env(app_name) when is_atom(app_name) do
    raw = Application.get_all_env(app_name)
    load(raw)
  end

  @spec schema_docs() :: String.t()
  def schema_docs do
    NimbleOptions.docs(@schema)
  end

  @spec validate_secret_key_base!(validated_config()) :: validated_config()
  defp validate_secret_key_base!(config) do
    case validate_secret_key_base(config) do
      :ok -> config
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @spec validate_secret_key_base(validated_config()) :: :ok | {:error, String.t()}
  defp validate_secret_key_base(%{secret_key_base: key}) do
    if byte_size(key) >= 64 do
      :ok
    else
      {:error, "secret_key_base must be at least 64 bytes, got #{byte_size(key)}"}
    end
  end
end
```
