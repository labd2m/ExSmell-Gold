```elixir
defmodule Auth.ApiKeyParser do
  @moduledoc """
  Parses API key strings issued by the developer portal.

  API keys follow a structured format that encodes the key type,
  deployment environment, and opaque secret material in a single string.
  This allows the authentication middleware to quickly route keys to the
  correct verification strategy before making any database calls.

  Format:
    "<TYPE>_<ENV>_<SECRET>"

  Key types:
    pk  — Public (read-only) key
    sk  — Secret (read-write) key
    wh  — Webhook signing secret

  Environments:
    live    — Production
    test    — Sandbox / staging
    preview — Ephemeral preview environment

  Examples:
    "pk_live_4xTzQmR9bVsW3nAeLKp7YdJcF"
    "sk_test_9kPqNmV2aLsB6cWdF8jRtXeZH"
    "wh_live_7bKmNvQ3cLpR9sWfJ2tYdXeAH"
  """

  require Logger

  @key_types   ~w(pk sk wh)
  @environments ~w(live test preview)

  defstruct [:type, :environment, :secret, :live?, :raw]

  @doc """
  Parses an API key string into a `%ApiKeyParser{}` struct.

  Returns `{:ok, struct}` when the key type and environment are recognised.
  Returns `{:error, reason}` when either prefix segment is invalid.
  """

  def parse(key) when is_binary(key) do
    parts  = String.split(key, "_")
    type   = Enum.at(parts, 0)
    env    = Enum.at(parts, 1)
    secret = Enum.at(parts, 2)

    with :ok <- validate_key_type(type),
         :ok <- validate_environment(env) do
      {:ok, %__MODULE__{
        type:        type,
        environment: env,
        secret:      secret,
        live?:       env == "live",
        raw:         key
      }}
    end
  end

  @doc """
  Returns a redacted representation of the API key, safe for logging.
  """
  def redact(%__MODULE__{type: type, environment: env, secret: secret}) do
    prefix = String.slice(secret || "", 0, 4)
    "#{type}_#{env}_#{prefix}****"
  end

  def redact(raw) when is_binary(raw) do
    case parse(raw) do
      {:ok, parsed} -> redact(parsed)
      _             -> "****_****_****"
    end
  end

  @doc """
  Returns true when the parsed key grants write access.
  """
  def write_access?(%__MODULE__{type: "sk"}), do: true
  def write_access?(_), do: false

  @doc """
  Returns true when the parsed key is a webhook signing secret.
  """
  def webhook_secret?(%__MODULE__{type: "wh"}), do: true
  def webhook_secret?(_), do: false

  @doc """
  Returns the key scope label used for audit logging.
  """
  def scope_label(%__MODULE__{type: "pk", environment: env}), do: "public:#{env}"
  def scope_label(%__MODULE__{type: "sk", environment: env}), do: "secret:#{env}"
  def scope_label(%__MODULE__{type: "wh", environment: env}), do: "webhook:#{env}"
  def scope_label(_), do: "unknown"

  @doc """
  Returns true when the key's environment matches the application's current run mode.
  """
  def matches_run_mode?(%__MODULE__{live?: true},  :production),  do: true
  def matches_run_mode?(%__MODULE__{live?: false}, :development),  do: true
  def matches_run_mode?(%__MODULE__{live?: false}, :test),         do: true
  def matches_run_mode?(_, _), do: false

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_key_type(type) when is_binary(type) do
    if type in @key_types do
      :ok
    else
      {:error, {:unknown_key_type, type}}
    end
  end

  defp validate_key_type(nil), do: {:error, :missing_key_type}
  defp validate_key_type(_),   do: {:error, :invalid_key_type}

  defp validate_environment(env) when is_binary(env) do
    if env in @environments do
      :ok
    else
      {:error, {:unknown_environment, env}}
    end
  end

  defp validate_environment(nil), do: {:error, :missing_environment}
  defp validate_environment(_),   do: {:error, :invalid_environment}
end
```
