```elixir
defmodule ApiKey.Record do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          owner_id: String.t(),
          prefix: String.t(),
          key_hash: String.t(),
          scopes: [String.t()],
          name: String.t(),
          last_used_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          active: boolean()
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "api_keys" do
    field :owner_id, :string
    field :prefix, :string
    field :key_hash, :string
    field :scopes, {:array, :string}, default: []
    field :name, :string
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :active, :boolean, default: true
    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, params) do
    record
    |> cast(params, [:owner_id, :prefix, :key_hash, :scopes, :name, :expires_at])
    |> validate_required([:owner_id, :prefix, :key_hash, :name])
  end
end

defmodule ApiKey.Manager do
  @moduledoc """
  Issues and verifies API keys with prefix-based lookup and scope enforcement.

  Keys are issued as `prefix_secret` strings where only a SHA-256 digest of
  the secret is stored. Verification extracts the prefix, looks up the record,
  hashes the candidate secret, and compares with a timing-safe equality check.
  Scope verification ensures the caller holds the required permission without
  exposing the full scope list in the returned error.
  """

  import Ecto.Query, warn: false

  alias ApiKey.{Record, Repo}

  @prefix_length 8
  @secret_bytes 32

  @spec issue(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, String.t(), Record.t()} | {:error, Ecto.Changeset.t()}
  def issue(owner_id, name, scopes \\ [], opts \\ []) when is_binary(owner_id) do
    prefix = generate_prefix()
    secret = :crypto.strong_rand_bytes(@secret_bytes) |> Base.url_encode64(padding: false)
    raw_key = "#{prefix}_#{secret}"
    key_hash = hash(secret)
    expires_at = Keyword.get(opts, :expires_at)

    params = %{owner_id: owner_id, prefix: prefix, key_hash: key_hash,
               scopes: scopes, name: name, expires_at: expires_at}

    case %Record{} |> Record.changeset(params) |> Repo.insert() do
      {:ok, record} -> {:ok, raw_key, record}
      {:error, _} = err -> err
    end
  end

  @spec verify(String.t(), String.t() | nil) ::
          {:ok, Record.t()} | {:error, :invalid | :expired | :inactive | :insufficient_scope}
  def verify(raw_key, required_scope \\ nil) when is_binary(raw_key) do
    with {:ok, prefix, secret} <- split_key(raw_key),
         {:ok, record} <- find_record(prefix),
         :ok <- check_active(record),
         :ok <- check_expiry(record),
         :ok <- verify_secret(secret, record.key_hash),
         :ok <- check_scope(record, required_scope) do
      touch_last_used(record)
      {:ok, record}
    end
  end

  @spec revoke(Ecto.UUID.t()) :: {:ok, Record.t()} | {:error, :not_found}
  def revoke(key_id) when is_binary(key_id) do
    case Repo.get(Record, key_id) do
      nil -> {:error, :not_found}
      record ->
        {:ok, updated} = record |> Ecto.Changeset.change(active: false) |> Repo.update()
        {:ok, updated}
    end
  end

  defp split_key(raw_key) do
    case String.split(raw_key, "_", parts: 2) do
      [prefix, secret] -> {:ok, prefix, secret}
      _ -> {:error, :invalid}
    end
  end

  defp find_record(prefix) do
    case Repo.get_by(Record, prefix: prefix) do
      nil -> {:error, :invalid}
      record -> {:ok, record}
    end
  end

  defp check_active(%Record{active: false}), do: {:error, :inactive}
  defp check_active(_), do: :ok

  defp check_expiry(%Record{expires_at: nil}), do: :ok
  defp check_expiry(%Record{expires_at: exp}) do
    if DateTime.compare(exp, DateTime.utc_now()) == :lt, do: {:error, :expired}, else: :ok
  end

  defp verify_secret(candidate, stored_hash) do
    computed = hash(candidate)
    if :crypto.hash_equals(computed, stored_hash), do: :ok, else: {:error, :invalid}
  end

  defp check_scope(_record, nil), do: :ok
  defp check_scope(%Record{scopes: scopes}, required) do
    if required in scopes, do: :ok, else: {:error, :insufficient_scope}
  end

  defp touch_last_used(record) do
    Task.start(fn ->
      record |> Ecto.Changeset.change(last_used_at: DateTime.utc_now()) |> Repo.update()
    end)
  end

  defp generate_prefix do
    :crypto.strong_rand_bytes(@prefix_length) |> Base.encode16(case: :lower)
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
```
