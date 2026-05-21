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

    normalize_phone_numbers()
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
end```
