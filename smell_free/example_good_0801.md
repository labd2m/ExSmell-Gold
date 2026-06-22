```elixir
defmodule MyApp.Feeds.NotificationDigest do
  @moduledoc """
  Aggregates unread in-app notifications into a periodic digest for each
  user. Rather than delivering each notification individually, the digest
  batches them into a single email summarising activity since the last
  digest was sent. Digests respect per-user frequency preferences and
  are skipped when there are no unread items.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Feeds.{InAppNotification, DigestRecord}
  alias MyApp.Mailer

  @type user_id :: String.t()
  @type frequency :: :daily | :weekly
  @type digest_result :: %{sent: non_neg_integer(), skipped: non_neg_integer()}

  @doc """
  Sends digests to all users whose next digest is due at or before now.
  Returns a summary of how many were sent and skipped.
  """
  @spec send_due_digests() :: digest_result()
  def send_due_digests do
    due_users = fetch_due_users()

    {sent, skipped} =
      Enum.reduce(due_users, {0, 0}, fn user_id, {s, sk} ->
        case send_digest(user_id) do
          {:ok, :sent} -> {s + 1, sk}
          {:ok, :skipped} -> {s, sk + 1}
        end
      end)

    %{sent: sent, skipped: skipped}
  end

  @doc """
  Sends a digest to `user_id` immediately, regardless of schedule.
  Returns `{:ok, :sent}` or `{:ok, :skipped}` when there is nothing new.
  """
  @spec send_digest(user_id()) :: {:ok, :sent} | {:ok, :skipped}
  def send_digest(user_id) when is_binary(user_id) do
    notifications = fetch_unread(user_id)

    if notifications == [] do
      advance_digest_schedule(user_id)
      {:ok, :skipped}
    else
      deliver_and_mark(user_id, notifications)
      {:ok, :sent}
    end
  end

  @spec fetch_due_users() :: [user_id()]
  defp fetch_due_users do
    now = DateTime.utc_now()

    DigestRecord
    |> where([d], d.next_digest_at <= ^now)
    |> select([d], d.user_id)
    |> Repo.all()
  end

  @spec fetch_unread(user_id()) :: [InAppNotification.t()]
  defp fetch_unread(user_id) do
    since = last_digest_at(user_id)

    InAppNotification
    |> where([n], n.recipient_id == ^user_id and is_nil(n.read_at))
    |> then(fn q ->
      if since, do: where(q, [n], n.inserted_at >= ^since), else: q
    end)
    |> order_by([n], desc: n.inserted_at)
    |> Repo.all()
  end

  @spec last_digest_at(user_id()) :: DateTime.t() | nil
  defp last_digest_at(user_id) do
    DigestRecord
    |> where([d], d.user_id == ^user_id)
    |> select([d], d.last_sent_at)
    |> Repo.one()
  end

  @spec deliver_and_mark(user_id(), [InAppNotification.t()]) :: :ok
  defp deliver_and_mark(user_id, notifications) do
    Mailer.deliver_notification_digest(user_id, notifications)

    ids = Enum.map(notifications, & &1.id)

    InAppNotification
    |> where([n], n.id in ^ids)
    |> Repo.update_all(set: [digested_at: DateTime.utc_now()])

    advance_digest_schedule(user_id)
    :ok
  end

  @spec advance_digest_schedule(user_id()) :: :ok
  defp advance_digest_schedule(user_id) do
    frequency = fetch_frequency(user_id)
    next = next_digest_at(frequency)

    Repo.insert(
      %DigestRecord{user_id: user_id, last_sent_at: DateTime.utc_now(), next_digest_at: next},
      on_conflict: {:replace, [:last_sent_at, :next_digest_at, :updated_at]},
      conflict_target: :user_id
    )

    :ok
  end

  @spec fetch_frequency(user_id()) :: frequency()
  defp fetch_frequency(user_id) do
    DigestRecord
    |> where([d], d.user_id == ^user_id)
    |> select([d], d.frequency)
    |> Repo.one()
    |> Kernel.||(:daily)
  end

  @spec next_digest_at(frequency()) :: DateTime.t()
  defp next_digest_at(:daily), do: DateTime.add(DateTime.utc_now(), 86_400, :second)
  defp next_digest_at(:weekly), do: DateTime.add(DateTime.utc_now(), 7 * 86_400, :second)
end
```
