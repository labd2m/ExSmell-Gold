# Annotated Example — Compile-time Global Configuration

## Metadata

- **Smell:** Compile-time global configuration
- **Expected Smell Location:** Module attribute `@ingest_endpoint` defined via `Application.fetch_env!/2` at the top of the module body
- **Affected Function(s):** `track/3`, `flush/0`
- **Explanation:** `Application.fetch_env!/2` is invoked at compile-time to set the analytics ingest endpoint URL in `@ingest_endpoint`. The `:analytics` application is not loaded at that point, causing Elixir to raise an `ArgumentError` or a warning. The URL is baked into the beam, so routing events to a different endpoint (e.g. staging vs production) at runtime is not possible without recompiling.

---

```elixir
defmodule Analytics.EventTracker do
  @moduledoc """
  Buffers and asynchronously forwards tracking events to the analytics
  ingestion endpoint. Events are batched in memory and flushed either
  on a timer or when the buffer fills.
  """

  use GenServer

  require Logger

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is called
  # VALIDATION: at module-compilation time. At that stage :analytics has not
  # VALIDATION: been started, so Elixir raises:
  # VALIDATION:   warning: Application.fetch_env!/2 is discouraged in the
  # VALIDATION:   module body, use Application.compile_env/3 instead
  # VALIDATION: The URL string is also frozen in the .beam bytecode; the
  # VALIDATION: application environment cannot override it at runtime.
  @ingest_endpoint Application.fetch_env!(:analytics, :ingest_endpoint)
  # VALIDATION: SMELL END

  @flush_interval_ms 5_000
  @max_buffer_size 200
  @request_timeout_ms 10_000

  defstruct buffer: [], pending_flush: nil

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec track(String.t(), String.t(), map()) :: :ok
  def track(event_name, user_id, properties \\ %{})
      when is_binary(event_name) and is_binary(user_id) do
    GenServer.cast(__MODULE__, {:track, build_event(event_name, user_id, properties)})
  end

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush, 15_000)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    timer = schedule_flush()
    Logger.info("EventTracker started", endpoint: @ingest_endpoint)
    {:ok, %__MODULE__{pending_flush: timer}}
  end

  @impl GenServer
  def handle_cast({:track, event}, %{buffer: buffer} = state) do
    new_buffer = [event | buffer]

    if length(new_buffer) >= @max_buffer_size do
      Process.cancel_timer(state.pending_flush)
      send_batch(new_buffer)
      {:noreply, %{state | buffer: [], pending_flush: schedule_flush()}}
    else
      {:noreply, %{state | buffer: new_buffer}}
    end
  end

  @impl GenServer
  def handle_info(:flush_timer, state) do
    unless state.buffer == [], do: send_batch(state.buffer)
    {:noreply, %{state | buffer: [], pending_flush: schedule_flush()}}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    unless state.buffer == [], do: send_batch(state.buffer)
    Process.cancel_timer(state.pending_flush)
    {:reply, :ok, %{state | buffer: [], pending_flush: schedule_flush()}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_event(name, user_id, properties) do
    %{
      event: name,
      user_id: user_id,
      properties: properties,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      session_id: generate_session_id()
    }
  end

  defp send_batch(events) do
    payload = Jason.encode!(%{events: Enum.reverse(events)})
    api_key = Application.get_env(:analytics, :api_key, "")

    headers = [
      {"Content-Type", "application/json"},
      {"X-API-Key", api_key}
    ]

    case http_client().post(@ingest_endpoint, payload, headers,
           timeout: @request_timeout_ms
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.debug("Analytics batch sent", count: length(events))

      {:ok, %{status: status}} ->
        Logger.warning("Analytics ingest rejected", status: status, count: length(events))

      {:error, reason} ->
        Logger.error("Analytics batch failed", reason: inspect(reason), count: length(events))
    end
  end

  defp schedule_flush do
    Process.send_after(self(), :flush_timer, @flush_interval_ms)
  end

  defp generate_session_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp http_client, do: Application.get_env(:analytics, :http_client, Analytics.HttpClient)
end
```
