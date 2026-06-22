```elixir
defmodule MyApp.Accounts.SessionCleaner do
  @moduledoc """
  A periodic Oban worker that deletes expired session tokens and
  revoked API keys from the database. Running this as a scheduled job
  rather than an inline trigger keeps the hot write path fast and gives
  operators visibility into how many stale records are removed each run.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 2

  require Logger

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Accounts.{SessionToken, ApiKey}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    now = DateTime.utc_now()
    results = %{
      expired_sessions: delete_expired_sessions(now),
      revoked_keys: delete_old_revoked_keys(now)
    }

    Logger.info("session_cleaner_complete", results)
    :ok
  end

  @spec delete_expired_sessions(DateTime.t()) :: non_neg_integer()
  defp delete_expired_sessions(now) do
    {count, _} =
      SessionToken
      |> where([t], t.expires_at < ^now)
      |> Repo.delete_all()

    count
  end

  @spec delete_old_revoked_keys(DateTime.t()) :: non_neg_integer()
  defp delete_old_revoked_keys(now) do
    cutoff = DateTime.add(now, -30, :day)

    {count, _} =
      ApiKey
      |> where([k], k.revoked == true and k.updated_at < ^cutoff)
      |> Repo.delete_all()

    count
  end
end
```
