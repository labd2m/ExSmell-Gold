# Annotated Example — Compile-time Global Configuration

## Metadata

- **Smell:** Compile-time global configuration
- **Expected Smell Location:** Module attribute `@flags_service_url` defined via `Application.fetch_env!/2` at the top of the module body
- **Affected Function(s):** `enabled?/2`, `get_variant/2`, `sync_flags/0`
- **Explanation:** `Application.fetch_env!/2` is called at compile-time to set `@flags_service_url`. Because `:feature_flags` is not loaded during compilation, Elixir raises an `ArgumentError` or a warning. The URL is embedded in the beam, so pointing the client at a different flags service (e.g. for blue-green deployment) is impossible at runtime without recompiling.

---

```elixir
defmodule FeatureFlags.Client do
  @moduledoc """
  Client for a remote feature-flag service. Flags are cached locally
  and refreshed periodically. Evaluations are performed against the
  local cache, with the remote service as the source of truth.
  """

  use GenServer

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 runs when the
  # VALIDATION: module is compiled. At that point the :feature_flags application
  # VALIDATION: has not been loaded, so Elixir raises:
  # VALIDATION:   ** (ArgumentError) could not fetch application environment
  # VALIDATION:     :flags_service_url for application :feature_flags
  # VALIDATION: The URL string is also baked into the .beam bytecode; changing
  # VALIDATION: the target service at runtime is impossible without recompiling.
  @flags_service_url Application.fetch_env!(:feature_flags, :flags_service_url)
  # VALIDATION: SMELL END

  @refresh_interval_ms 30_000
  @request_timeout_ms 5_000

  defstruct flags: %{}, last_synced_at: nil

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec enabled?(String.t(), String.t() | nil) :: boolean()
  def enabled?(flag_name, user_id \\ nil) do
    GenServer.call(__MODULE__, {:enabled?, flag_name, user_id})
  end

  @spec get_variant(String.t(), String.t()) :: String.t() | nil
  def get_variant(flag_name, user_id) do
    GenServer.call(__MODULE__, {:get_variant, flag_name, user_id})
  end

  @spec sync_flags() :: :ok | {:error, term()}
  def sync_flags do
    GenServer.call(__MODULE__, :sync, 15_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    state =
      case fetch_all_flags() do
        {:ok, flags} -> %__MODULE__{flags: flags, last_synced_at: DateTime.utc_now()}
        {:error, _} -> %__MODULE__{}
      end

    schedule_refresh()
    Logger.info("FeatureFlags client started", service: @flags_service_url)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:enabled?, flag_name, user_id}, _from, state) do
    result = evaluate_flag(state.flags, flag_name, user_id)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:get_variant, flag_name, user_id}, _from, state) do
    variant = evaluate_variant(state.flags, flag_name, user_id)
    {:reply, variant, state}
  end

  @impl GenServer
  def handle_call(:sync, _from, state) do
    case fetch_all_flags() do
      {:ok, flags} ->
        new_state = %{state | flags: flags, last_synced_at: DateTime.utc_now()}
        {:reply, :ok, new_state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    new_state =
      case fetch_all_flags() do
        {:ok, flags} ->
          Logger.debug("Feature flags refreshed", count: map_size(flags))
          %{state | flags: flags, last_synced_at: DateTime.utc_now()}

        {:error, reason} ->
          Logger.warning("Failed to refresh flags", reason: inspect(reason))
          state
      end

    schedule_refresh()
    {:noreply, new_state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_all_flags do
    url = @flags_service_url <> "/api/v1/flags"
    api_key = Application.get_env(:feature_flags, :api_key, "")

    headers = [{"X-API-Key", api_key}, {"Accept", "application/json"}]

    case http_client().get(url, headers, timeout: @request_timeout_ms) do
      {:ok, %{status: 200, body: body}} ->
        flags =
          Jason.decode!(body)
          |> Map.get("flags", [])
          |> Map.new(&{&1["name"], &1})

        {:ok, flags}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp evaluate_flag(flags, flag_name, user_id) do
    case Map.get(flags, flag_name) do
      nil -> false
      %{"enabled" => false} -> false
      %{"enabled" => true, "rollout_percentage" => pct} when is_number(pct) ->
        user_in_rollout?(user_id, flag_name, pct)
      %{"enabled" => true} -> true
      _ -> false
    end
  end

  defp evaluate_variant(flags, flag_name, user_id) do
    case Map.get(flags, flag_name) do
      %{"variants" => variants} when is_list(variants) ->
        select_variant(variants, flag_name, user_id)
      _ -> nil
    end
  end

  defp user_in_rollout?(nil, _, _), do: false

  defp user_in_rollout?(user_id, flag_name, percentage) do
    hash = :erlang.phash2({user_id, flag_name}, 100)
    hash < percentage
  end

  defp select_variant(variants, flag_name, user_id) do
    bucket = :erlang.phash2({user_id, flag_name}, 100)

    Enum.reduce_while(variants, 0, fn %{"name" => name, "weight" => weight}, acc ->
      new_acc = acc + weight
      if bucket < new_acc, do: {:halt, name}, else: {:cont, new_acc}
    end)
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval_ms)
  defp http_client, do: Application.get_env(:feature_flags, :http_client, FeatureFlags.HttpClient)
end
```
