# Annotated Example 40 — Modules with Identical Names

## Metadata

- **Smell name:** Modules with identical names
- **Expected smell location:** Both `defmodule AppConfig.Loader` declarations
- **Affected functions:** `AppConfig.Loader.load/0`, `AppConfig.Loader.get/1`, `AppConfig.Loader.get!/1`, `AppConfig.Loader.reload/0`, `AppConfig.Loader.validate!/0`
- **Short explanation:** Two different source files both declare `defmodule AppConfig.Loader`. BEAM silently drops one of the definitions at load time. In a configuration context this is especially harmful: if the module providing `load/0` or `validate!/0` is discarded, the application may start with missing or unvalidated config, causing hard-to-diagnose failures throughout the system.

---

```elixir
# ── file: lib/app_config/loader.ex ──────────────────────────────────────────

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This is a smell because `AppConfig.Loader` is declared here and
# again in a second block below. BEAM will discard one definition, potentially
# losing config loading and validation functions critical to application startup.

defmodule AppConfig.Loader do
  @moduledoc """
  Loads, validates, and provides runtime access to application configuration.
  Merges environment variables, runtime config files, and compile-time defaults.
  Defined in `lib/app_config/loader.ex`.
  """

  alias AppConfig.{Schema, EnvReader, FileReader, ConfigStore}

  @config_file_path Application.compile_env(:my_app, :config_file, "config/runtime.json")
  @required_keys ~w(database_url secret_key_base payment_gateway_key)a

  @type config_key :: atom()
  @type config_value :: String.t() | integer() | boolean() | map()

  @doc """
  Load configuration from all sources (env vars, config file, defaults).
  Stores the merged result in `ConfigStore` for fast runtime access.
  """
  @spec load() :: {:ok, map()} | {:error, String.t()}
  def load do
    with {:ok, file_cfg} <- FileReader.read(@config_file_path),
         env_cfg <- EnvReader.read_all(),
         merged <- deep_merge(file_cfg, env_cfg),
         {:ok, validated} <- Schema.validate(merged) do
      ConfigStore.put_all(validated)
      {:ok, validated}
    end
  end

  @doc "Fetch a config value by key. Returns `{:ok, value}` or `:not_found`."
  @spec get(config_key()) :: {:ok, config_value()} | :not_found
  def get(key) when is_atom(key) do
    ConfigStore.get(key)
  end

  @doc "Fetch a config value or raise if missing."
  @spec get!(config_key()) :: config_value()
  def get!(key) when is_atom(key) do
    case ConfigStore.get(key) do
      {:ok, value} -> value
      :not_found -> raise "Required config key missing: #{key}"
    end
  end

  @doc "Reload configuration from all sources at runtime without restarting."
  @spec reload() :: {:ok, map()} | {:error, String.t()}
  def reload do
    ConfigStore.clear()
    load()
  end

  @doc """
  Validate that all required configuration keys are present and well-formed.
  Raises `RuntimeError` with a descriptive message on failure.
  """
  @spec validate!() :: :ok
  def validate! do
    missing =
      Enum.filter(@required_keys, fn key ->
        case ConfigStore.get(key) do
          {:ok, v} when v != nil and v != "" -> false
          _ -> true
        end
      end)

    unless missing == [] do
      raise "Application config validation failed. Missing keys: #{inspect(missing)}"
    end

    :ok
  end

  @doc "Return the full merged configuration map for inspection."
  @spec all() :: map()
  def all do
    ConfigStore.all()
  end

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _key, v1, v2 ->
      if is_map(v1) and is_map(v2), do: deep_merge(v1, v2), else: v2
    end)
  end

  defp deep_merge(_base, override), do: override
end

# VALIDATION: SMELL END

# ── file: lib/app_config/loader_watcher.ex  (hot-reload watcher added later;
#    developer accidentally reused the module name instead of a sub-module) ───

# VALIDATION: SMELL START - Modules with identical names
# VALIDATION: This second `defmodule AppConfig.Loader` replaces the first in
# BEAM. `load/0`, `get/1`, `get!/1`, `reload/0`, and `validate!/0` all vanish,
# leaving the application unable to access or validate its own configuration.

defmodule AppConfig.Loader do
  @moduledoc """
  File-system watcher for hot-reloading configuration changes in development.
  Was intended to be `AppConfig.Loader.Watcher` but was accidentally given
  the same module name as the core config loader.
  """

  use GenServer

  alias AppConfig.{FileReader, ConfigStore, Schema}

  @poll_interval_ms 5_000
  @config_path Application.compile_env(:my_app, :config_file, "config/runtime.json")

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force an immediate configuration refresh check."
  @spec check_now() :: :ok
  def check_now do
    GenServer.cast(__MODULE__, :check)
  end

  ## Server callbacks

  @impl true
  def init(_opts) do
    {:ok, mtime} = file_mtime(@config_path)
    schedule_poll()
    {:ok, %{last_mtime: mtime}}
  end

  @impl true
  def handle_cast(:check, state) do
    {:noreply, maybe_reload(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = maybe_reload(state)
    schedule_poll()
    {:noreply, new_state}
  end

  defp maybe_reload(%{last_mtime: last} = state) do
    case file_mtime(@config_path) do
      {:ok, ^last} ->
        state

      {:ok, new_mtime} ->
        with {:ok, cfg} <- FileReader.read(@config_path),
             {:ok, validated} <- Schema.validate(cfg) do
          ConfigStore.put_all(validated)
        end

        %{state | last_mtime: new_mtime}

      {:error, _} ->
        state
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> {:ok, mtime}
      {:error, reason} -> {:error, reason}
    end
  end
end

# VALIDATION: SMELL END
```
