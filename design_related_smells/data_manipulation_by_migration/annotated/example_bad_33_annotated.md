# Code Smell Annotation

- **Smell name:** Data manipulation by migration
- **Expected smell location:** `change/0` function
- **Affected function(s):** `change/0`, `hash_existing_tokens/0`
- **Short explanation:** The migration adds a `hashed_token` column to `api_keys` and immediately reads every plaintext `token` value from existing rows, hashes it, and writes the hash back to the table. Transforming and persisting cryptographic derivatives of existing column values is data manipulation that should be separated into a Mix task.

---

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

    # VALIDATION: SMELL START - Data manipulation by migration
    # VALIDATION: This is a smell because the migration fetches all existing
    # api_keys rows, derives a hashed_token by applying a SHA-256 digest to
    # the plaintext token, extracts a display prefix, and persists both values
    # back to the database. This is a data transformation operation — not
    # a schema change — and belongs in a dedicated Mix task separate from
    # the Ecto.Migration module.
    hash_existing_tokens()
    # VALIDATION: SMELL END

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
