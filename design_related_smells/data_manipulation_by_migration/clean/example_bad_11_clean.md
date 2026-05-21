```elixir
defmodule Accounts.Repo.Migrations.AddNormalizedEmailToAccounts do
  use Ecto.Migration

  import Ecto.Query
  alias Accounts.Repo

  def change do
    alter table("accounts") do
      add :normalized_email, :string, null: true
    end

    create unique_index("accounts", [:normalized_email])

    alter table("accounts") do
      modify :email, :string, null: false
    end

    flush()

    populate_normalized_emails()
  end

  defp populate_normalized_emails do
    from(a in "accounts",
      where: is_nil(a.normalized_email),
      select: %{id: a.id, email: a.email}
    )
    |> Repo.all()
    |> Enum.each(fn %{id: id, email: email} ->
      normalized = normalize_email(email)

      from(a in "accounts", where: a.id == ^id)
      |> Repo.update_all(set: [normalized_email: normalized])
    end)
  end

  defp normalize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_email(_), do: nil
end
```
