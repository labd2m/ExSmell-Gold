```elixir
defmodule Digests.DigestAssembler do
  @moduledoc """
  Assembles and delivers periodic email digests summarising activity
  within a user's account. Digest frequency (daily or weekly) is stored
  in user preferences. The assembler is driven by an Oban cron job that
  runs hourly; each execution selects users whose digest window has elapsed
  and fans out one Oban job per user so individual delivery failures are
  isolated and retried independently.
  """

  use Oban.Worker, queue: :digests, max_attempts: 3

  alias Digests.{Activity, DigestPreference, Repo}
  alias MyApp.Accounts

  require Logger

  @frequencies [:daily, :weekly]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mode" => "dispatch"}}) do
    now = DateTime.utc_now()
    dispatched = dispatch_due_digests(now)
    Logger.info("Digest dispatch complete", jobs_enqueued: dispatched)
    :ok
  end

  def perform(%Oban.Job{args: %{"user_id" => user_id, "window_start" => ws, "window_end" => we}}) do
    with {:ok, window_start} <- DateTime.from_iso8601(ws),
         {:ok, window_end} <- DateTime.from_iso8601(we),
         {:ok, user} <- Accounts.fetch_user(user_id),
         {:ok, activities} <- Activity.for_user(user_id, window_start, window_end),
         :ok <- deliver_digest(user, activities, window_start, window_end) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp dispatch_due_digests(now) do
    @frequencies
    |> Enum.flat_map(&users_due_for_digest(&1, now))
    |> Enum.map(fn {user_id, window_start, window_end} ->
      args = %{
        "user_id" => user_id,
        "window_start" => DateTime.to_iso8601(window_start),
        "window_end" => DateTime.to_iso8601(window_end)
      }

      new(args) |> Oban.insert()
    end)
    |> Enum.count(&match?({:ok, _}, &1))
  end

  defp users_due_for_digest(frequency, now) when frequency in @frequencies do
    window_hours = if frequency == :daily, do: 24, else: 168
    cutoff = DateTime.add(now, -window_hours * 3_600, :second)

    DigestPreference
    |> where([p], p.frequency == ^frequency)
    |> where([p], p.last_sent_at < ^cutoff or is_nil(p.last_sent_at))
    |> join(:inner, [p], u in Accounts.User, on: p.user_id == u.id and u.active == true)
    |> select([p, u], {p.user_id, p.last_sent_at})
    |> Repo.all()
    |> Enum.map(fn {user_id, last_sent} ->
      window_start = last_sent || DateTime.add(now, -window_hours * 3_600, :second)
      {user_id, window_start, now}
    end)
  end

  defp deliver_digest(_user, [], _window_start, _window_end) do
    :ok
  end

  defp deliver_digest(user, activities, window_start, window_end) do
    grouped = group_by_type(activities)
    summary = build_summary(grouped, window_start, window_end)

    case Digests.Mailer.deliver(user, summary) do
      {:ok, _} ->
        record_sent(user.id, window_end)
        :ok

      {:error, reason} ->
        Logger.warning("Digest delivery failed",
          user_id: user.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp group_by_type(activities) do
    Enum.group_by(activities, & &1.type)
  end

  defp build_summary(grouped, window_start, window_end) do
    %{
      period_start: window_start,
      period_end: window_end,
      sections: Enum.map(grouped, fn {type, items} ->
        %{type: type, count: length(items), items: Enum.take(items, 10)}
      end),
      total_events: grouped |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    }
  end

  defp record_sent(user_id, sent_at) do
    DigestPreference
    |> where([p], p.user_id == ^user_id)
    |> Repo.update_all(set: [last_sent_at: sent_at])
  end
end
```
