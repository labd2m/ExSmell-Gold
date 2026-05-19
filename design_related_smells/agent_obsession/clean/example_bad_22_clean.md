```elixir
defmodule NotificationStore do
  @moduledoc "Initializes the shared notification pipeline agent."

  def start do
    {:ok, pid} = Agent.start_link(fn ->
      %{
        pending: [],
        delivered: [],
        suppressed: [],
        delivery_counts: %{}
      }
    end)
    pid
  end
end

defmodule NotificationQueue do
  @moduledoc """
  Enqueues outgoing notifications into the shared pipeline agent.
  """

  def enqueue(pid, notification) do
    enriched =
      notification
      |> Map.put_new(:id, generate_id())
      |> Map.put_new(:inserted_at, DateTime.utc_now())
      |> Map.put_new(:status, :pending)

    Agent.update(pid, fn state ->
      %{state | pending: state.pending ++ [enriched]}
    end)

    {:ok, enriched.id}
  end

  def peek(pid, n \\ 5) do
    Agent.get(pid, fn state -> Enum.take(state.pending, n) end)
  end

  def pending_count(pid) do
    Agent.get(pid, fn state -> length(state.pending) end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

defmodule NotificationFilter do
  @moduledoc """
  Suppresses duplicate notifications already delivered to a recipient.
  """

  def suppress_duplicates(pid) do
    delivered_keys =
      Agent.get(pid, fn state ->
        MapSet.new(state.delivered, fn n -> {n.recipient_id, n.type} end)
      end)

    Agent.update(pid, fn state ->
      {keep, suppress} =
        Enum.split_with(state.pending, fn n ->
          not MapSet.member?(delivered_keys, {n.recipient_id, n.type})
        end)

      suppressed_entries =
        Enum.map(suppress, fn n -> %{n | status: :suppressed, suppressed_at: DateTime.utc_now()} end)

      %{state |
        pending: keep,
        suppressed: state.suppressed ++ suppressed_entries
      }
    end)
  end

  def suppressed_count(pid) do
    Agent.get(pid, fn state -> length(state.suppressed) end)
  end
end

defmodule NotificationDelivery do
  @moduledoc """
  Marks notifications as delivered after successful send.
  """

  def mark_delivered(pid, notification_id) do
    found = Agent.get(pid, fn state ->
      Enum.find(state.pending, fn n -> n.id == notification_id end)
    end)

    case found do
      nil ->
        {:error, :not_found}

      notification ->
        delivered = %{notification | status: :delivered, delivered_at: DateTime.utc_now()}

        Agent.update(pid, fn state ->
          updated_pending = Enum.reject(state.pending, fn n -> n.id == notification_id end)
          updated_counts =
            Map.update(state.delivery_counts, notification.recipient_id, 1, &(&1 + 1))

          %{state |
            pending: updated_pending,
            delivered: [delivered | state.delivered],
            delivery_counts: updated_counts
          }
        end)

        {:ok, delivered}
    end
  end

  def delivered_to(pid, recipient_id) do
    Agent.get(pid, fn state ->
      Enum.filter(state.delivered, fn n -> n.recipient_id == recipient_id end)
    end)
  end
end

defmodule NotificationMetrics do
  @moduledoc """
  Computes pipeline health metrics from the shared notification agent.
  """

  def stats(pid) do
    state = Agent.get(pid, fn s -> s end)

    top_recipients =
      state.delivery_counts
      |> Enum.sort_by(fn {_k, v} -> v end, :desc)
      |> Enum.take(5)

    %{
      pending: length(state.pending),
      delivered: length(state.delivered),
      suppressed: length(state.suppressed),
      top_recipients: top_recipients,
      total_processed: length(state.delivered) + length(state.suppressed),
      snapshot_at: DateTime.utc_now()
    }
  end
end
```
