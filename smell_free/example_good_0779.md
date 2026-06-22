```elixir
defmodule Notifications.BatchDispatcher do
  @moduledoc """
  Dispatches notifications to multiple recipients in parallel with bounded
  concurrency. Builds per-recipient payloads, calls the channel module for
  each recipient, and collects delivery outcomes. Failed deliveries are
  logged and returned separately so callers can retry or escalate without
  re-sending to recipients who already received the notification.
  """

  require Logger

  alias Notifications.Channel

  @type recipient_id :: String.t()
  @type payload :: map()
  @type channel :: :email | :sms | :push
  @type delivery_outcome :: {:ok, recipient_id()} | {:error, recipient_id(), term()}
  @type batch_result :: %{
          succeeded: [recipient_id()],
          failed: [{recipient_id(), term()}],
          total: non_neg_integer()
        }

  @default_concurrency 20
  @default_timeout_ms 10_000

  @doc """
  Dispatches `payload` to all `recipient_ids` via `channel`. Runs
  `max_concurrency` deliveries at a time. Returns a batch result map.
  """
  @spec dispatch([recipient_id()], channel(), payload(), keyword()) :: batch_result()
  def dispatch(recipient_ids, channel, payload, opts \\ [])
      when is_list(recipient_ids) and is_atom(channel) and is_map(payload) do
    concurrency = Keyword.get(opts, :max_concurrency, @default_concurrency)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    channel_mod = channel_module(channel)

    outcomes =
      recipient_ids
      |> Enum.chunk_every(concurrency)
      |> Enum.flat_map(fn batch ->
        batch
        |> Enum.map(fn rid ->
          Task.async(fn -> deliver(channel_mod, rid, payload) end)
        end)
        |> Enum.map(fn task ->
          case Task.yield(task, timeout_ms) || Task.shutdown(task) do
            {:ok, result} -> result
            nil -> {:error, :timeout}
            {:exit, reason} -> {:error, :task_crashed, reason}
          end
        end)
      end)

    summarise(outcomes, recipient_ids)
  end

  defp deliver(channel_mod, recipient_id, payload) do
    case channel_mod.deliver(recipient_id, payload) do
      :ok -> {:ok, recipient_id}
      {:error, reason} -> {:error, recipient_id, reason}
    end
  rescue
    e -> {:error, recipient_id, Exception.message(e)}
  end

  defp summarise(outcomes, recipient_ids) do
    {succeeded, failed} =
      Enum.reduce(outcomes, {[], []}, fn
        {:ok, rid}, {s, f} -> {[rid | s], f}
        {:error, rid, reason}, {s, f} ->
          Logger.warning("[BatchDispatcher] Delivery failed for #{rid}: #{inspect(reason)}")
          {s, [{rid, reason} | f]}
        {:error, reason}, {s, f} ->
          Logger.warning("[BatchDispatcher] Delivery failed: #{inspect(reason)}")
          {s, f}
      end)

    %{
      succeeded: Enum.reverse(succeeded),
      failed: Enum.reverse(failed),
      total: length(recipient_ids)
    }
  end

  defp channel_module(:email), do: Notifications.EmailChannel
  defp channel_module(:sms), do: Notifications.SMSChannel
  defp channel_module(:push), do: Notifications.PushChannel
end
```
