# Annotated Example – Large Messages

| Field | Value |
|---|---|
| **Smell name** | Large messages |
| **Expected smell location** | `Analytics.TelemetryCollector.forward_raw_events/2` |
| **Affected function(s)** | `forward_raw_events/2` |
| **Short explanation** | The collector accumulates raw telemetry events in its state buffer and, when asked to flush, sends the entire accumulated buffer—potentially millions of individual event maps—to an aggregation process as one message. This enormous message blocks the collector and saturates the aggregator's mailbox. |

```elixir
defmodule Analytics.RawEvent do
  @enforce_keys [:id, :type, :user_id, :session_id, :occurred_at, :payload]
  defstruct [
    :id,
    :type,
    :user_id,
    :session_id,
    :occurred_at,
    :payload,
    :sdk_version,
    :platform,
    :geo
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          user_id: String.t() | nil,
          session_id: String.t(),
          occurred_at: DateTime.t(),
          payload: map(),
          sdk_version: String.t(),
          platform: String.t(),
          geo: map() | nil
        }
end

defmodule Analytics.EventBuffer do
  @moduledoc "Ring-buffer GenServer that holds raw inbound telemetry events."
  use GenServer

  @max_buffer 200_000

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def ingest(event), do: GenServer.cast(__MODULE__, {:ingest, event})

  def flush, do: GenServer.call(__MODULE__, :flush, 30_000)

  @impl true
  def init(_), do: {:ok, build_initial_buffer()}

  @impl true
  def handle_cast({:ingest, event}, buffer) when length(buffer) < @max_buffer do
    {:noreply, [event | buffer]}
  end

  def handle_cast({:ingest, _}, buffer), do: {:noreply, buffer}

  @impl true
  def handle_call(:flush, _from, buffer) do
    {:reply, Enum.reverse(buffer), []}
  end

  defp build_initial_buffer do
    now = DateTime.utc_now()
    event_types = ["page_view", "click", "scroll", "form_submit", "video_play", "purchase", "search"]
    platforms = ["web", "ios", "android"]

    Enum.map(1..150_000, fn n ->
      %Analytics.RawEvent{
        id: "evt_#{n}_#{:rand.uniform(999_999_999)}",
        type: Enum.random(event_types),
        user_id: if(rem(n, 5) == 0, do: nil, else: "usr_#{rem(n, 100_000) + 1}"),
        session_id: "sess_#{rem(n, 500_000) + 1}",
        occurred_at: DateTime.add(now, -:rand.uniform(3600), :second),
        platform: Enum.random(platforms),
        sdk_version: Enum.random(["2.1.0", "2.2.0", "3.0.1"]),
        geo: %{
          country: Enum.random(["US", "BR", "DE", "JP", "GB", "IN"]),
          region: "Region-#{rem(n, 50) + 1}",
          city: "City-#{rem(n, 200) + 1}",
          lat: -90.0 + :rand.uniform() * 180,
          lon: -180.0 + :rand.uniform() * 360
        },
        payload:
          case rem(n, 7) do
            0 ->
              %{
                page: "/products/#{rem(n, 1000)}",
                referrer: "https://google.com",
                time_on_page_ms: :rand.uniform(60_000),
                scroll_depth: :rand.uniform(100)
              }

            1 ->
              %{
                element_id: "btn_#{rem(n, 500)}",
                element_type: "button",
                page: "/checkout",
                x: :rand.uniform(1920),
                y: :rand.uniform(1080)
              }

            2 ->
              %{
                query: "product query #{rem(n, 1000)}",
                results_count: :rand.uniform(200),
                filters: %{category: "cat_#{rem(n, 20)}", price_max: :rand.uniform(500)}
              }

            _ ->
              %{
                value: :rand.uniform() * 999,
                label: "event_label_#{rem(n, 100)}",
                custom_1: "val_#{rem(n, 50)}",
                custom_2: rem(n, 10)
              }
          end
      }
    end)
  end
end

defmodule Analytics.AggregationWorker do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, [], opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_info({:raw_events, pipeline_id, events}, state) do
    {:noreply, [{pipeline_id, length(events)} | state]}
  end
end

defmodule Analytics.TelemetryCollector do
  @moduledoc """
  Flushes the raw event buffer and forwards all events to the
  aggregation worker for roll-up, funnel analysis, and anomaly detection.
  """

  require Logger

  @spec forward_raw_events(pid(), String.t()) :: :ok
  def forward_raw_events(aggregation_pid, pipeline_id) do
    Logger.info("Flushing telemetry buffer for pipeline #{pipeline_id}...")

    events = Analytics.EventBuffer.flush()

    Logger.info(
      "Flushed #{length(events)} raw events. Forwarding to aggregation worker..."
    )

    # VALIDATION: SMELL START - Large messages
    # VALIDATION: This is a smell because `events` is a list that may contain
    # up to 150,000 RawEvent structs, each with a geo map and a variably-shaped
    # payload map. Sending this entire list in one process message forces the
    # BEAM to deep-copy several hundred megabytes across process heaps,
    # blocking the TelemetryCollector process for a long time and potentially
    # causing downstream processing latency to spike dramatically.
    send(aggregation_pid, {:raw_events, pipeline_id, events})
    # VALIDATION: SMELL END

    Logger.info("Raw event batch forwarded for pipeline #{pipeline_id}.")
    :ok
  end
end
```
