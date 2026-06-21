```elixir
defmodule MyApp.Config.Loader do
  @moduledoc """
  Loads, validates, and exposes typed application configuration at
  startup. All required values are checked for presence and format before
  the application finishes booting, so configuration errors surface as
  clear startup failures rather than cryptic runtime crashes.

  Downstream modules call `get/1` or `fetch!/1` to read individual values
  from the validated config store without accessing the Application env
  directly, keeping the configuration surface area explicit and testable.
  """

  use GenServer

  require Logger

  @table __MODULE__

  @required_keys [
    :database_url,
    :secret_key_base,
    :aws_access_key_id,
    :aws_secret_access_key,
    :aws_region,
    :smtp_host
  ]

  @optional_keys [
    :smtp_port,
    :smtp_username,
    :smtp_password,
    :cdn_base_url,
    :sentry_dsn,
    :stripe_secret_key
  ]

  @doc "Starts the configuration loader."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the value for `key`, or `nil` if the key was not set.
  """
  @spec get(atom()) :: term() | nil
  def get(key) when is_atom(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  @doc """
  Returns the value for `key`.
  Raises `KeyError` if the key is absent or was not in the required set.
  """
  @spec fetch!(atom()) :: term()
  def fetch!(key) when is_atom(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> raise KeyError, key: key, term: "application config"
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    case load_and_validate() do
      {:ok, config} ->
        Enum.each(config, fn {k, v} -> :ets.insert(@table, {k, v}) end)
        Logger.info("config_loaded", keys: length(config))
        {:ok, %{}}

      {:error, missing} ->
        {:stop, {:config_missing, missing}}
    end
  end

  @spec load_and_validate() :: {:ok, keyword()} | {:error, [atom()]}
  defp load_and_validate do
    env = Application.get_all_env(:my_app)

    missing =
      Enum.reject(@required_keys, fn key ->
        value = Keyword.get(env, key)
        is_binary(value) and byte_size(value) > 0
      end)

    if missing == [] do
      all_keys = @required_keys ++ @optional_keys
      config = Enum.flat_map(all_keys, fn key ->
        case Keyword.get(env, key) do
          nil -> []
          value -> [{key, value}]
        end
      end)

      {:ok, config}
    else
      Enum.each(missing, fn key ->
        Logger.error("config_key_missing", key: key)
      end)

      {:error, missing}
    end
  end
end
```
