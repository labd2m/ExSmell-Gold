# Annotated Example — Agent Obsession

| Field | Value |
|---|---|
| **Smell name** | Agent Obsession |
| **Expected smell location** | Multiple modules: `NotificationQueue`, `NotificationFilter`, `NotificationDelivery`, `NotificationMetrics` |
| **Affected functions** | `NotificationQueue.enqueue/2`, `NotificationFilter.suppress_duplicates/1`, `NotificationDelivery.mark_delivered/2`, `NotificationMetrics.stats/1` |
| **Short explanation** | Four notification-pipeline modules each interact directly with an Agent holding notification state. The agent's internal structure is scattered across all four modules, creating tight implicit coupling and maintenance risk. |

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

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because NotificationQueue directly calls Agent.update/2
  # to push into the agent's `pending` list. The internal state shape is owned by this
  # module just as much as by any other, meaning responsibility is spread across modules.
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
  # VALIDATION: SMELL END
end

defmodule NotificationFilter do
  @moduledoc """
  Suppresses duplicate notifications already delivered to a recipient.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because NotificationFilter directly reads and updates
  # multiple fields of the agent (`delivered`, `pending`, `suppressed`) through Agent.get/2
  # and Agent.update/2, further spreading agent state ownership across the system.
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
  # VALIDATION: SMELL END
end

defmodule NotificationDelivery do
  @moduledoc """
  Marks notifications as delivered after successful send.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because NotificationDelivery is a third module directly
  # calling Agent.update/2, mutating the shared state in-place. There is no central contract
  # preventing inconsistent state writes from any of these modules.
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
  # VALIDATION: SMELL END
end

defmodule NotificationMetrics do
  @moduledoc """
  Computes pipeline health metrics from the shared notification agent.
  """

  # VALIDATION: SMELL START - Agent Obsession
  # VALIDATION: This is a smell because NotificationMetrics is a fourth module accessing
  # the raw agent state via Agent.get/2. Any renaming of agent keys requires changes in all
  # four modules, and the risk of inconsistent interpretation grows with each module added.
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
  # VALIDATION: SMELL END
end
```
