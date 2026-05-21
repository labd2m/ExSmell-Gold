```elixir
defmodule Accounts.Repo.Migrations.AddNormalizedEmailToUsers do
  use Ecto.Migration

  import Ecto.Query
  alias Accounts.Repo

  @batch_size 500

  def change do
    alter table("users") do
      add :normalized_email, :string, null: true
    end

    create index("users", [:normalized_email])

    flush()

    populate_normalized_emails()

    alter table("users") do
      modify :normalized_email, :string, null: false
    end

    create unique_index("users", [:normalized_email])
  end

  defp populate_normalized_emails do
    total = Repo.one(from u in "users", select: count(u.id))
    pages = ceil(total / @batch_size)

    Enum.each(0..(pages - 1), fn page ->
      offset = page * @batch_size

      rows =
        from(u in "users",
          select: %{id: u.id, email: u.email},
          limit: @batch_size,
          offset: ^offset
        )
        |> Repo.all()

      Enum.each(rows, fn %{id: id, email: email} ->
        normalized =
          email
          |> String.downcase()
          |> String.trim()

        from(u in "users", where: u.id == ^id)
        |> Repo.update_all(set: [normalized_email: normalized])
      end)
    end)
  end
end
```
