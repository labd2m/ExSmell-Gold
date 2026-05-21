# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `normalize_phone_numbers/0`, `normalize_phone/1`
- **Short explanation:** The migration adds `formatted_phone` and `phone_country_code` columns to `customers`, then reads every existing row, strips and reformats the `phone` value, and writes the normalized version back to the table. Reformatting and normalizing existing field values is a data transformation responsibility that should be in a Mix task, not a migration.

---

```elixir
defmodule Retail.Repo.Migrations.AddFormattedPhoneToCustomers do
  use Ecto.Migration

  import Ecto.Query
  alias Retail.Repo

  def change do
    alter table("customers") do
      add :formatted_phone,      :string, null: true
      add :phone_country_code,   :string, size: 4, null: true
      add :phone_normalized_at,  :utc_datetime, null: true
    end

    create index("customers", [:formatted_phone])

    flush()

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration reads the phone field
    # from every customer row, strips non-numeric characters, applies E.164
    # formatting, and writes the result back to formatted_phone. Normalizing
    # and transforming existing field values for all rows is data manipulation
    # work that does not belong inside Ecto.Migration. It should be a separate
    # Mix task to preserve cohesion and testability.
    normalize_phone_numbers()
    # VALIDATION: SMELL END
  end

  defp normalize_phone_numbers do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      from(c in "customers",
        where: not is_nil(c.phone) and c.phone != "",
        select: %{id: c.id, phone: c.phone}
      )
      |> Repo.all()

    Enum.each(rows, fn %{id: id, phone: phone} ->
      case normalize_phone(phone) do
        {:ok, formatted, country_code} ->
          from(c in "customers", where: c.id == ^id)
          |> Repo.update_all(
            set: [
              formatted_phone: formatted,
              phone_country_code: country_code,
              phone_normalized_at: now
            ]
          )

        :error ->
          :ok
      end
    end)
  end

  defp normalize_phone(phone) do
    digits = String.replace(phone, ~r/\D/, "")

    cond do
      String.starts_with?(digits, "1") and byte_size(digits) == 11 ->
        formatted = "+1-#{String.slice(digits, 1, 3)}-#{String.slice(digits, 4, 3)}-#{String.slice(digits, 7, 4)}"
        {:ok, formatted, "1"}

      String.starts_with?(digits, "44") and byte_size(digits) >= 11 ->
        formatted = "+44 #{String.slice(digits, 2, 100)}"
        {:ok, formatted, "44"}

      byte_size(digits) >= 10 ->
        {:ok, digits, "unknown"}

      true ->
        :error
    end
  end
end
```
