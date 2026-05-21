```elixir
defmodule Accounts.Repo.Migrations.AddIsVerifiedToUsers do
  use Ecto.Migration

  import Ecto.Query
  alias Accounts.Repo

  @days_active_threshold 30

  def change do
    alter table("users") do
      add :is_verified,         :boolean, default: false, null: false
      add :verified_at,         :utc_datetime, null: true
      add :verification_source, :string, default: "auto", null: false
    end

    create index("users", [:is_verified])

    flush()

    backfill_verification_status()
  end

  defp backfill_verification_status do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@days_active_threshold * 86_400, :second)
      |> DateTime.truncate(:second)

    candidates =
      from(u in "users",
        where: u.email_confirmed == true and u.inserted_at <= ^cutoff,
        select: %{id: u.id, inserted_at: u.inserted_at}
      )
      |> Repo.all()

    Enum.each(candidates, fn %{id: id, inserted_at: inserted_at} ->
      verified_at = DateTime.truncate(inserted_at, :second)

      from(u in "users", where: u.id == ^id)
      |> Repo.update_all(
        set: [is_verified: true, verified_at: verified_at, verification_source: "migration"]
      )
    end)
  end
end
```
