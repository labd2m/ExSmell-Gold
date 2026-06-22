```elixir
defmodule MyApp.Analytics.EventAggregatorPipeline do
  @moduledoc """
  A Broadway pipeline that consumes raw analytics events from a queue,
  aggregates them into per-user and per-session summaries within each
  batch, and bulk-upserts the results into the `analytics_summaries`
  table. Aggregating before writing reduces database write pressure by
  an order of magnitude compared to writing each event individually.
  """

  use Broadway

  require Logger

  alias Broadway.Message
  alias MyApp.Repo
  alias MyApp.Analytics.Summary

  import Ecto.Query, warn: false

  @doc "Starts the analytics aggregator pipeline."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Broadway.start_link(__MODULE__, broadway_config(opts))
  end

  @impl Broadway
  def handle_message(_processor, %Message{} = message, _context) do
    case decode_event(message.data) do
      {:ok, event} -> Message.put_data(message, event)
      {:error, _} -> Message.failed(message, :decode_error)
    end
  end

  @impl Broadway
  def handle_batch(:default, messages, _batch_info, _context) do
    events = Enum.flat_map(messages, fn m ->
      case m.status do
        :ok -> [m.data]
        _ -> []
      end
    end)

    events
    |> aggregate_events()
    |> bulk_upsert()

    messages
  end

  @spec decode_event(binary()) :: {:ok, map()} | {:error, term()}
  defp decode_event(data) do
    case Jason.decode(data) do
      {:ok, %{"user_id" => _, "event" => _} = event} -> {:ok, event}
      {:ok, _} -> {:error, :missing_fields}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec aggregate_events([map()]) :: [map()]
  defp aggregate_events(events) do
    events
    |> Enum.group_by(fn e ->
      {e["user_id"], e["session_id"], truncate_to_hour(e["occurred_at"])}
    end)
    |> Enum.map(fn {{user_id, session_id, hour}, group} ->
      %{
        user_id: user_id,
        session_id: session_id,
        hour: hour,
        event_count: length(group),
        page_views: Enum.count(group, &(&1["event"] == "page_view")),
        clicks: Enum.count(group, &(&1["event"] == "click"))
      }
    end)
  end

  @spec bulk_upsert([map()]) :: :ok
  defp bulk_upsert([]), do: :ok

  defp bulk_upsert(summaries) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stamped = Enum.map(summaries, &Map.merge(&1, %{inserted_at: now, updated_at: now}))

    Repo.insert_all(
      Summary,
      stamped,
      on_conflict: {:replace, [:event_count, :page_views, :clicks, :updated_at]},
      conflict_target: [:user_id, :session_id, :hour]
    )

    :ok
  end

  @spec truncate_to_hour(String.t() | nil) :: DateTime.t()
  defp truncate_to_hour(nil), do: DateTime.utc_now() |> Map.put(:minute, 0) |> Map.put(:second, 0)

  defp truncate_to_hour(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> %{dt | minute: 0, second: 0, microsecond: {0, 0}}
      _ -> DateTime.utc_now() |> Map.put(:minute, 0) |> Map.put(:second, 0)
    end
  end

  @spec broadway_config(keyword()) :: keyword()
  defp broadway_config(opts) do
    [
      name: __MODULE__,
      producer: [
        module: {BroadwaySQS.Producer, queue_url: Application.fetch_env!(:my_app, :analytics_queue_url)},
        concurrency: 1
      ],
      processors: [default: [concurrency: Keyword.get(opts, :concurrency, 5)]],
      batchers: [
        default: [
          batch_size: Keyword.get(opts, :batch_size, 200),
          batch_timeout: 2_000
        ]
      ]
    ]
  end
end
```
