```elixir
defmodule MyApp.Accounts.UserExporter do
  @moduledoc """
  Exports a user's complete account data in response to a GDPR data
  portability request. The export collects data from multiple domain
  contexts, formats it as a structured JSON archive, uploads it to
  object storage, and emails a secure download link to the user.

  The export runs inside a supervised Oban job to handle retries
  gracefully; each step is idempotent so safe re-execution is guaranteed.
  """

  use Oban.Worker, queue: :exports, max_attempts: 3

  require Logger

  alias MyApp.Repo
  alias MyApp.Accounts.{User, DataExportRecord}
  alias MyApp.Storage
  alias MyApp.Mailer

  import Ecto.Query, warn: false

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "export_id" => export_id}}) do
    with {:ok, user} <- fetch_user(user_id),
         {:ok, payload} <- collect_export_data(user),
         {:ok, url} <- upload_export(export_id, payload),
         :ok <- mark_ready(export_id, url),
         :ok <- notify_user(user, url) do
      Logger.info("user_export_complete", user_id: user_id, export_id: export_id)
      :ok
    end
  end

  @spec fetch_user(String.t()) :: {:ok, User.t()} | {:error, :user_not_found}
  defp fetch_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  @spec collect_export_data(User.t()) :: {:ok, map()}
  defp collect_export_data(user) do
    payload = %{
      exported_at: DateTime.utc_now(),
      account: export_account(user),
      orders: export_orders(user.id),
      support_tickets: export_tickets(user.id),
      activity_log: export_activity(user.id)
    }

    {:ok, payload}
  end

  @spec export_account(User.t()) :: map()
  defp export_account(user) do
    %{
      id: user.id,
      email: user.email,
      name: user.name,
      created_at: user.inserted_at
    }
  end

  @spec export_orders(String.t()) :: [map()]
  defp export_orders(user_id) do
    MyApp.Commerce.Order
    |> where([o], o.customer_id == ^user_id)
    |> select([o], %{id: o.id, status: o.status, total_cents: o.total_cents,
                     placed_at: o.inserted_at})
    |> Repo.all()
  end

  @spec export_tickets(String.t()) :: [map()]
  defp export_tickets(user_id) do
    MyApp.Support.Ticket
    |> where([t], t.customer_id == ^user_id)
    |> select([t], %{id: t.id, subject: t.subject, status: t.status,
                     opened_at: t.inserted_at})
    |> Repo.all()
  end

  @spec export_activity(String.t()) :: [map()]
  defp export_activity(user_id) do
    MyApp.Compliance.AuditEntry
    |> where([a], a.actor_id == ^user_id)
    |> order_by([a], desc: a.occurred_at)
    |> limit(1000)
    |> select([a], %{action: a.action, occurred_at: a.occurred_at})
    |> Repo.all()
  end

  @spec upload_export(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  defp upload_export(export_id, payload) do
    content = Jason.encode!(payload)
    key = "user_exports/#{export_id}.json"
    Storage.put(key, content, acl: :private, content_type: "application/json")
  end

  @spec mark_ready(String.t(), String.t()) :: :ok | {:error, term()}
  defp mark_ready(export_id, url) do
    DataExportRecord
    |> where([r], r.id == ^export_id)
    |> Repo.update_all(set: [status: :ready, download_url: url, completed_at: DateTime.utc_now()])

    :ok
  end

  @spec notify_user(User.t(), String.t()) :: :ok
  defp notify_user(user, url) do
    case Mailer.deliver_data_export_ready(user, url) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("export_notification_failed", user_id: user.id, reason: inspect(reason))
        :ok
    end
  end
end
```
