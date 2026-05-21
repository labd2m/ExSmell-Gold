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

    normalize_phone_numbers()
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
