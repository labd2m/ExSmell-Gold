```elixir
defmodule Platform.Repo.Migrations.AddHashedTokenToApiKeys do
  use Ecto.Migration

  import Ecto.Query
  alias Platform.Repo

  def change do
    alter table("api_keys") do
      add :hashed_token, :string, null: true
      add :token_prefix, :string, null: true
    end

    flush()

    hash_existing_tokens()

    alter table("api_keys") do
      modify :hashed_token, :string, null: false
    end

    create unique_index("api_keys", [:hashed_token])
  end

  defp hash_existing_tokens do
    api_keys =
      from(k in "api_keys",
        where: not is_nil(k.token),
        select: %{id: k.id, token: k.token}
      )
      |> Repo.all()

    Enum.each(api_keys, fn %{id: id, token: token} ->
      hashed = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
      prefix = String.slice(token, 0, 8)

      from(k in "api_keys", where: k.id == ^id)
      |> Repo.update_all(set: [hashed_token: hashed, token_prefix: prefix])
    end)
  end
end
```
