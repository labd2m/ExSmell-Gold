# Annotated Example — GenServer Envy

- **Smell name:** GenServer Envy
- **Expected smell location:** `RenewalCoordinatorTask` — `Task` coordinating subscription renewals
- **Affected function(s):** `start_coordinator/1`, `coordinator_loop/1`
- **Short explanation:** The `Task` runs a loop that processes renewal queues, handles payment retries, notifies customers, and updates subscription state across many message exchanges — clearly a `GenServer` role.

```elixir
defmodule MyApp.RenewalCoordinatorTask do
  @moduledoc """
  Coordinates subscription renewal processing — charges due accounts,
  handles grace periods, and sends expiry notifications.
  """

  alias MyApp.{PaymentGateway, Mailer, Repo, AuditLog}
  alias MyApp.Subscriptions.{Subscription, RenewalAttempt}

  @grace_period_days 3
  @max_renewal_attempts 3
  @retry_delay_ms 5_000

  def start_coordinator(config) do
    # VALIDATION: SMELL START - GenServer Envy
    # VALIDATION: This is a smell because a Task is used to run a persistent
    # coordinator process with multiple message types, mutable state, reply
    # semantics, and scheduled internal messages. The coordinator manages renewal
    # queues, retry backoff, payment integration, and customer notifications —
    # the exact kind of complex, long-lived server behavior that GenServer provides.
    # A Task is only appropriate for a single isolated asynchronous computation.
    Task.start_link(fn ->
      state = %{
        config: config,
        renewal_queue: :queue.new(),
        in_progress: %{},
        completed: [],
        failed: []
      }

      send(self(), :load_due_subscriptions)
      coordinator_loop(state)
    end)
  end

  defp coordinator_loop(state) do
    receive do
      :load_due_subscriptions ->
        due = Repo.all_due_for_renewal(DateTime.utc_now())
        new_queue = Enum.reduce(due, state.renewal_queue, &:queue.in({&1, 1}, &2))
        Process.send_after(self(), :process_batch, 1_000)
        coordinator_loop(%{state | renewal_queue: new_queue})

      :process_batch ->
        batch_size = state.config.batch_size || 10
        {to_process, remaining} = dequeue_n(state.renewal_queue, batch_size)

        coordinator_pid = self()

        Enum.each(to_process, fn {sub, attempt} ->
          Task.start(fn ->
            result = attempt_renewal(sub, attempt)
            send(coordinator_pid, {:renewal_result, sub.id, attempt, result})
          end)
        end)

        new_in_flight =
          Enum.into(to_process, state.in_progress, fn {sub, attempt} ->
            {sub.id, {sub, attempt}}
          end)

        Process.send_after(self(), :process_batch, 10_000)
        coordinator_loop(%{state | renewal_queue: remaining, in_progress: new_in_flight})

      {:renewal_result, sub_id, attempt, {:ok, receipt}} ->
        {sub, _} = Map.fetch!(state.in_progress, sub_id)
        Repo.update!(%{sub | status: :active, renewed_at: DateTime.utc_now()})
        Mailer.deliver_renewal_receipt(sub.user_email, receipt)
        AuditLog.record(:subscription_renewed, %{sub_id: sub_id, attempt: attempt})
        new_in_progress = Map.delete(state.in_progress, sub_id)
        coordinator_loop(%{state | in_progress: new_in_progress, completed: [sub | state.completed]})

      {:renewal_result, sub_id, attempt, {:error, reason}} ->
        {sub, _} = Map.fetch!(state.in_progress, sub_id)
        new_in_progress = Map.delete(state.in_progress, sub_id)

        if attempt < @max_renewal_attempts do
          Process.send_after(self(), {:retry, sub, attempt + 1}, @retry_delay_ms * attempt)
          coordinator_loop(%{state | in_progress: new_in_progress})
        else
          grace_expires = DateTime.add(DateTime.utc_now(), @grace_period_days * 86_400, :second)
          Repo.update!(%{sub | status: :grace_period, grace_expires_at: grace_expires})
          Mailer.deliver_payment_failure_notice(sub.user_email, reason)
          AuditLog.record(:renewal_failed, %{sub_id: sub_id, reason: reason})
          coordinator_loop(%{state | in_progress: new_in_progress, failed: [sub | state.failed]})
        end

      {:retry, sub, attempt} ->
        new_queue = :queue.in({sub, attempt}, state.renewal_queue)
        coordinator_loop(%{state | renewal_queue: new_queue})

      {:get_stats, from} ->
        stats = %{
          queued: :queue.len(state.renewal_queue),
          in_progress: map_size(state.in_progress),
          completed: length(state.completed),
          failed: length(state.failed)
        }
        send(from, {:ok, stats})
        coordinator_loop(state)

      :stop ->
        :ok
    end
  end

  # VALIDATION: SMELL END

  defp attempt_renewal(sub, _attempt) do
    PaymentGateway.charge(sub.payment_method_id, sub.renewal_amount_cents, sub.currency)
  end

  defp dequeue_n(queue, n) do
    Enum.reduce(1..n, {[], queue}, fn _, {acc, q} ->
      case :queue.out(q) do
        {{:value, item}, rest} -> {[item | acc], rest}
        {:empty, q} -> {acc, q}
      end
    end)
  end

  def get_stats(pid) do
    send(pid, {:get_stats, self()})

    receive do
      {:ok, stats} -> {:ok, stats}
    after
      5_000 -> {:error, :timeout}
    end
  end
end
```
