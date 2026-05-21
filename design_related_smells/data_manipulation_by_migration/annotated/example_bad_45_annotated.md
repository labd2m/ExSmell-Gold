# Code Smell Example 45

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `normalize_phone_numbers/0`
- **Short explanation:** The migration adds a `normalized_phone` column to `contacts` (structural change) and then reads every existing phone number, applies formatting logic, and writes the result back into the new column (data manipulation), blending schema evolution with application-level data transformation.

```elixir
defmodule CrmApp.Repo.Migrations.AddNormalizedPhoneToContacts do
  use Ecto.Migration

  import Ecto.Query
  alias CrmApp.Repo

  def change do
    alter table("contacts") do
      add :normalized_phone, :string, null: true
      add :phone_normalized_at, :utc_datetime, null: true
    end

    create index("contacts", [:normalized_phone])

    flush()

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration performs both a structural
    # change (adding columns) and data manipulation (reading raw phone values,
    # transforming them with application logic, and persisting the result). This
    # dual responsibility reduces cohesion and makes the migration harder to test.
    normalize_phone_numbers()
    # VALIDATION: SMELL END
  end

  defp normalize_phone_numbers do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(c in "contacts",
      where: not is_nil(c.phone),
      select: {c.id, c.phone}
    )
    |> Repo.all()
    |> Enum.each(fn {id, raw_phone} ->
      normalized = do_normalize(raw_phone)

      from(c in "contacts",
        where: c.id == ^id,
        update: [set: [normalized_phone: ^normalized, phone_normalized_at: ^now]]
      )
      |> Repo.update_all([])
    end)
  end

  defp do_normalize(phone) when is_binary(phone) do
    digits = String.replace(phone, ~r/\D/, "")

    case String.length(digits) do
      10 -> "+1#{digits}"
      11 -> "+#{digits}"
      _  -> phone
    end
  end
end
```
