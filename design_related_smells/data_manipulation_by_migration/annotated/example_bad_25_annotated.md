# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `populate_normalized_emails/0`
- **Short explanation:** The migration adds the `normalized_email` column and then immediately iterates over all existing user rows to compute and store the lowercased, trimmed version of each email. This data backfill is a data-manipulation concern that does not belong inside an `Ecto.Migration` module.

---

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

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration performs a data
    # transformation (lowercasing and trimming existing email values and
    # persisting them to a new column) after making the structural change.
    # This couples schema evolution with data ETL logic and makes the
    # migration harder to test and reason about in isolation.
    populate_normalized_emails()
    # VALIDATION: SMELL END

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
