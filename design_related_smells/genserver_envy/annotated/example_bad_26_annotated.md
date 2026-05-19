# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `DeadLetterProcessorTask` — `Task` acting as a persistent DLQ management server
- **Affected function(s):** `start_processor/1`, `processor_loop/1`
- **Short explanation:** The `Task` maintains a dead-letter queue, handles enqueue/replay/discard commands from multiple callers, tracks retry history, and sends replies — a fully-fledged server that should be implemented as a `GenServer`.

```elixir
defmodule MyApp.DeadLetterProcessorTask do
  @moduledoc """
  Manages a dead-letter queue for failed message processing.
  Supports inspection, selective replay, and discard operations.
  """

  alias MyApp.{MessageRouter, AuditLog, AlertService, Repo}
  alias MyApp.Messaging.{DeadLetter, ReplayResult}

  @max_replay_attempts 3
  @alert_threshold 100

  def start_processor(config) do
    # VALIDATION: SMELL START - GenServer Envy
    # VALIDATION: This is a smell because a Task is used to build a persistent
    # dead-letter queue processor that receives enqueue/replay/discard/query
    # commands from many callers, maintains state across all interactions, sends
    # replies, and triggers side effects (alerts, DB writes, routing). Handling
    # diverse message types with request/reply semantics over a process lifetime
    # is the explicit purpose of GenServer, not Task.
    Task.start_link(fn ->
      existing =
        Repo.all_dead_letters()
        |> Enum.into(%{}, &{&1.id, &1})

      state = %{
        config: config,
        letters: existing,
        replay_history: %{},
        alert_sent_at: nil
      }

      processor_loop(state)
    end)
  end

  defp processor_loop(state) do
    receive do
      {:enqueue, from, %DeadLetter{} = letter} ->
        case Repo.insert(letter) do
          {:ok, saved} ->
            new_letters = Map.put(state.letters, saved.id, saved)
            new_state = %{state | letters: new_letters}

            new_state =
              if map_size(new_state.letters) >= @alert_threshold do
                now = DateTime.utc_now()

                should_alert =
                  is_nil(state.alert_sent_at) or
                    DateTime.diff(now, state.alert_sent_at, :second) > 3_600

                if should_alert do
                  AlertService.notify(:dlq_threshold_reached, %{count: map_size(new_state.letters)})
                  %{new_state | alert_sent_at: now}
                else
                  new_state
                end
              else
                new_state
              end

            send(from, {:ok, saved.id})
            processor_loop(new_state)

          {:error, reason} ->
            send(from, {:error, reason})
            processor_loop(state)
        end

      {:replay, from, letter_id} ->
        case Map.fetch(state.letters, letter_id) do
          :error ->
            send(from, {:error, :not_found})
            processor_loop(state)

          {:ok, letter} ->
            history = Map.get(state.replay_history, letter_id, [])

            if length(history) >= @max_replay_attempts do
              send(from, {:error, :max_replays_exceeded})
              processor_loop(state)
            else
              result =
                case MessageRouter.route(letter.original_message) do
                  :ok ->
                    new_letters = Map.delete(state.letters, letter_id)
                    Repo.delete!(letter)
                    AuditLog.record(:dlq_replayed, %{letter_id: letter_id})
                    {:ok, :replayed}

                  {:error, reason} ->
                    {:error, reason}
                end

              replay_entry = %ReplayResult{
                letter_id: letter_id,
                attempted_at: DateTime.utc_now(),
                result: result
              }

              new_history = Map.put(state.replay_history, letter_id, [replay_entry | history])

              new_letters =
                if match?({:ok, _}, result) do
                  Map.delete(state.letters, letter_id)
                else
                  state.letters
                end

              send(from, result)
              processor_loop(%{state | letters: new_letters, replay_history: new_history})
            end
        end

      {:discard, from, letter_id} ->
        case Map.fetch(state.letters, letter_id) do
          :error ->
            send(from, {:error, :not_found})
            processor_loop(state)

          {:ok, letter} ->
            Repo.delete!(letter)
            AuditLog.record(:dlq_discarded, %{letter_id: letter_id})
            new_letters = Map.delete(state.letters, letter_id)
            send(from, :ok)
            processor_loop(%{state | letters: new_letters})
        end

      {:query, from, filters} ->
        matching =
          state.letters
          |> Map.values()
          |> Enum.filter(fn letter ->
            Enum.all?(filters, fn
              {:topic, t} -> letter.topic == t
              {:since, dt} -> DateTime.compare(letter.failed_at, dt) in [:gt, :eq]
              _ -> true
            end)
          end)

        send(from, {:ok, matching})
        processor_loop(state)

      {:get_stats, from} ->
        stats = %{
          total: map_size(state.letters),
          topics: state.letters |> Map.values() |> Enum.map(& &1.topic) |> Enum.frequencies()
        }
        send(from, {:ok, stats})
        processor_loop(state)

      :stop ->
        :ok
    end
  end

  # VALIDATION: SMELL END

  def enqueue(pid, dead_letter) do
    send(pid, {:enqueue, self(), dead_letter})

    receive do
      {:ok, id} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end

  def replay(pid, letter_id) do
    send(pid, {:replay, self(), letter_id})

    receive do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    after
      10_000 -> {:error, :timeout}
    end
  end

  def discard(pid, letter_id) do
    send(pid, {:discard, self(), letter_id})

    receive do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end
end
```
