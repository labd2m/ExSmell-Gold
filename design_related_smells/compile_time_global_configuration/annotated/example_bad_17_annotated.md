# Annotated Bad Example 17

## Metadata

- **Smell name:** Compile-time global configuration
- **Expected smell location:** Module attribute `@ingest_endpoint` defined at the top of `Analytics.EventPublisher`
- **Affected function(s):** `track/2`, `track_batch/1`, `flush_buffer/0`
- **Short explanation:** `Application.fetch_env!/2` is called in the module body to set the analytics ingest endpoint as a module attribute. This happens at compile-time, before the `:analytics` OTP application configuration is loaded, and Elixir may therefore raise a warning or `ArgumentError` during compilation.

---

```elixir
defmodule Analytics.EventPublisher do
  @moduledoc """
  Buffers and publishes analytics events to the configured ingest endpoint.
  Events are accumulated in an in-process buffer and flushed either on a
  configurable interval or when the buffer reaches its size limit.
  """

  use GenServer
  require Logger

  @flush_interval_ms 5_000
  @max_buffer_size 200

  # VALIDATION: SMELL START - Compile-time global configuration
  # VALIDATION: This is a smell because Application.fetch_env!/2 is evaluated in the
  # VALIDATION: module body to populate a module attribute. Module attributes are
  # VALIDATION: resolved at compile-time, but the :analytics application environment
  # VALIDATION: may not yet be loaded at that point, causing Elixir to raise a
  # VALIDATION: warning or ArgumentError during compilation.
  @ingest_endpoint Application.fetch_env!(:analytics, :ingest_endpoint)
  # VALIDATION: SMELL END

  @api_key Application.get_env(:analytics, :api_key, "")

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues a single analytics event for asynchronous delivery.

  ## Parameters
    - `event_name` - A string or atom identifying the event type.
    - `properties` - A map of event metadata.
  """
  @spec track(String.t() | atom(), map()) :: :ok
  def track(event_name, properties \\ %{}) do
    event = build_event(event_name, properties)
    GenServer.cast(__MODULE__, {:track, event})
  end

  @doc """
  Enqueues multiple events in a single call. Useful for session replay or
  bulk import scenarios.
  """
  @spec track_batch([{String.t() | atom(), map()}]) :: :ok
  def track_batch(events) when is_list(events) do
    built = Enum.map(events, fn {name, props} -> build_event(name, props) end)
    GenServer.cast(__MODULE__, {:track_batch, built})
  end

  @doc """
  Forces an immediate flush of the internal buffer to the ingest endpoint.
  Returns the number of events successfully delivered.
  """
  @spec flush_buffer() :: {:ok, non_neg_integer()} | {:error, term()}
  def flush_buffer do
    GenServer.call(__MODULE__, :flush)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(_opts) do
    schedule_flush()
    {:ok, %{buffer: [], dropped: 0}}
  end

  @impl GenServer
  def handle_cast({:track, event}, %{buffer: buf} = state) do
    new_buf = [event | buf]

    if length(new_buf) >= @max_buffer_size do
      {:ok, _} = do_flush(new_buf)
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, %{state | buffer: new_buf}}
    end
  end

  def handle_cast({:track_batch, events}, %{buffer: buf} = state) do
    combined = events ++ buf

    if length(combined) >= @max_buffer_size do
      {:ok, _} = do_flush(combined)
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, %{state | buffer: combined}}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, %{buffer: buf} = state) do
    result = do_flush(buf)
    {:reply, result, %{state | buffer: []}}
  end

  @impl GenServer
  def handle_info(:flush, %{buffer: []} = state) do
    schedule_flush()
    {:noreply, state}
  end

  def handle_info(:flush, %{buffer: buf} = state) do
    do_flush(buf)
    schedule_flush()
    {:noreply, %{state | buffer: []}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_flush([]), do: {:ok, 0}

  defp do_flush(events) do
    payload = Jason.encode!(%{events: Enum.reverse(events)})
    headers = [{"Content-Type", "application/json"}, {"X-Api-Key", @api_key}]

    case HTTPoison.post(@ingest_endpoint, payload, headers, recv_timeout: 8_000) do
      {:ok, %HTTPoison.Response{status_code: code}} when code in 200..204 ->
        Logger.info("Analytics flush delivered count=#{length(events)}")
        {:ok, length(events)}

      {:ok, %HTTPoison.Response{status_code: code}} ->
        Logger.error("Analytics flush rejected status=#{code}")
        {:error, {:rejected, code}}

      {:error, reason} ->
        Logger.error("Analytics flush failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_event(name, properties) do
    %{
      event: to_string(name),
      properties: properties,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end
end
```
