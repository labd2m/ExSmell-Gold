```elixir
defmodule Projection.Rebuilder do
  @moduledoc """
  Rebuilds a read-model projection from scratch by replaying stored events
  through a configurable handler module. Supports optional checkpointing
  to resume from a known position after interruption.
  """

  @type rebuild_opts :: [
          batch_size: pos_integer(),
          from_position: non_neg_integer(),
          checkpoint_every: pos_integer()
        ]

  @type rebuild_result :: %{
          events_processed: non_neg_integer(),
          final_position: non_neg_integer(),
          duration_ms: non_neg_integer()
        }

  @spec rebuild(module(), module(), rebuild_opts()) ::
          {:ok, rebuild_result()} | {:error, term()}
  def rebuild(event_store, handler_module, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 500)
    from_position = Keyword.get(opts, :from_position, 0)
    checkpoint_every = Keyword.get(opts, :checkpoint_every, 1000)

    start_ms = System.monotonic_time(:millisecond)

    case handler_module.reset() do
      :ok ->
        result = stream_and_apply(event_store, handler_module, from_position, batch_size,
                                  checkpoint_every, 0)
        duration = System.monotonic_time(:millisecond) - start_ms

        case result do
          {:ok, stats} -> {:ok, Map.put(stats, :duration_ms, duration)}
          error -> error
        end

      {:error, reason} ->
        {:error, {:reset_failed, reason}}
    end
  end

  defp stream_and_apply(store, handler, position, batch_size, checkpoint_every, total_processed) do
    case store.read_from(position, limit: batch_size) do
      {:ok, []} ->
        {:ok, %{events_processed: total_processed, final_position: position}}

      {:ok, events} ->
        case apply_batch(handler, events) do
          :ok ->
            new_total = total_processed + length(events)
            last_position = events |> List.last() |> Map.fetch!(:global_position)

            if rem(new_total, checkpoint_every) < batch_size do
              handler.checkpoint(last_position)
            end

            stream_and_apply(store, handler, last_position + 1, batch_size,
                             checkpoint_every, new_total)

          {:error, reason} ->
            {:error, {:apply_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp apply_batch(handler, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case handler.apply(event) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end

defmodule Projection.UserSummary do
  @moduledoc """
  Read-model projection that maintains a denormalized summary of user accounts.
  Implements the handler interface required by `Projection.Rebuilder`.
  """

  alias MyApp.Repo
  alias MyApp.ReadModels.UserSummaryRecord

  @spec reset() :: :ok | {:error, term()}
  def reset do
    case Repo.delete_all(UserSummaryRecord) do
      {_count, nil} -> :ok
      _ -> {:error, :delete_failed}
    end
  end

  @spec checkpoint(non_neg_integer()) :: :ok
  def checkpoint(position) do
    :ok = MyApp.ProjectionMeta.set_checkpoint(__MODULE__, position)
  end

  @spec apply(map()) :: :ok | {:error, term()}
  def apply(%{event_type: "UserRegistered", data: data}) do
    case Repo.insert(%UserSummaryRecord{user_id: data["id"], email: data["email"],
                                        registered_at: data["occurred_at"]}) do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, cs}
    end
  end

  def apply(%{event_type: "UserConfirmed", data: data}) do
    case Repo.get_by(UserSummaryRecord, user_id: data["id"]) do
      nil -> :ok
      record ->
        case Repo.update(Ecto.Changeset.change(record, confirmed: true)) do
          {:ok, _} -> :ok
          {:error, cs} -> {:error, cs}
        end
    end
  end

  def apply(_unhandled_event), do: :ok
end
```
