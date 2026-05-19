```elixir
defmodule MyApp.WebhookDeliveryTask do
  @moduledoc """
  Manages outbound webhook delivery with exponential backoff retries
  and per-endpoint delivery tracking.
  """

  alias MyApp.{HTTPClient, AuditLog}
  alias MyApp.Webhooks.{Delivery, Endpoint}

  @max_attempts 5
  @base_backoff_ms 1_000
  @max_backoff_ms 30_000

  def start_delivery_manager(config) do
    Task.start_link(fn ->
      state = %{
        config: config,
        pending: :queue.new(),
        in_flight: %{},
        history: [],
        endpoint_stats: %{}
      }

      delivery_loop(state)
    end)
  end

  defp delivery_loop(state) do
    receive do
      {:deliver, from, %Delivery{} = delivery} ->
        ref = make_ref()
        new_pending = :queue.in({ref, delivery, 1}, state.pending)
        send(from, {:ok, ref})
        new_state = drain_queue(%{state | pending: new_pending})
        delivery_loop(new_state)

      {:delivery_result, ref, result} ->
        case Map.fetch(state.in_flight, ref) do
          :error ->
            delivery_loop(state)

          {:ok, {delivery, attempt}} ->
            new_in_flight = Map.delete(state.in_flight, ref)

            new_state =
              case result do
                {:ok, status_code} when status_code in 200..299 ->
                  record = %{delivery: delivery, attempt: attempt, status: :success, at: DateTime.utc_now()}
                  AuditLog.record(:webhook_delivered, record)
                  stats = update_stats(state.endpoint_stats, delivery.endpoint_id, :success)
                  %{state | in_flight: new_in_flight, history: [record | state.history], endpoint_stats: stats}

                err ->
                  reason = extract_reason(err)

                  if attempt < @max_attempts do
                    backoff = min(@base_backoff_ms * :math.pow(2, attempt - 1) |> trunc(), @max_backoff_ms)
                    Process.send_after(self(), {:retry, ref, delivery, attempt + 1}, backoff)
                    %{state | in_flight: new_in_flight}
                  else
                    record = %{delivery: delivery, attempt: attempt, status: :failed, reason: reason, at: DateTime.utc_now()}
                    AuditLog.record(:webhook_failed, record)
                    stats = update_stats(state.endpoint_stats, delivery.endpoint_id, :failure)
                    %{state | in_flight: new_in_flight, history: [record | state.history], endpoint_stats: stats}
                  end
              end

            delivery_loop(drain_queue(new_state))
        end

      {:retry, _ref, delivery, attempt} ->
        new_pending = :queue.in({make_ref(), delivery, attempt}, state.pending)
        delivery_loop(drain_queue(%{state | pending: new_pending}))

      {:get_stats, from} ->
        send(from, {:ok, state.endpoint_stats})
        delivery_loop(state)

      {:get_history, from, endpoint_id} ->
        filtered =
          Enum.filter(state.history, fn r -> r.delivery.endpoint_id == endpoint_id end)

        send(from, {:ok, filtered})
        delivery_loop(state)

      :stop ->
        :ok
    end
  end


  defp drain_queue(state) do
    max_in_flight = state.config.max_concurrent || 10

    if map_size(state.in_flight) >= max_in_flight do
      state
    else
      case :queue.out(state.pending) do
        {:empty, _} ->
          state

        {{:value, {ref, delivery, attempt}}, rest} ->
          manager = self()

          Task.start(fn ->
            result =
              HTTPClient.post(delivery.url, delivery.payload,
                headers: delivery.headers,
                timeout: 10_000
              )

            send(manager, {:delivery_result, ref, result})
          end)

          drain_queue(%{state | pending: rest, in_flight: Map.put(state.in_flight, ref, {delivery, attempt})})
      end
    end
  end

  defp update_stats(stats, endpoint_id, outcome) do
    Map.update(stats, endpoint_id, %{success: 0, failure: 0}, fn s ->
      Map.update!(s, outcome, &(&1 + 1))
    end)
  end

  defp extract_reason({:error, reason}), do: reason
  defp extract_reason({:ok, code}), do: {:http_error, code}

  def deliver(pid, delivery) do
    send(pid, {:deliver, self(), delivery})

    receive do
      {:ok, ref} -> {:ok, ref}
    after
      5_000 -> {:error, :timeout}
    end
  end
end
```
