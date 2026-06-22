```elixir
defmodule Compliance.Audit.Trail do
  @moduledoc """
  Provides tamper-evident audit trail recording for compliance-sensitive
  operations. Each entry is chained to the previous via a SHA-256 hash,
  making retrospective modification detectable. All writes go through
  this module's public API; direct Repo access is prohibited.
  """

  alias Compliance.Repo
  alias Compliance.Audit.{Entry, ChainVerification}
  import Ecto.Query, warn: false

  @type record_opts :: [actor_id: String.t(), metadata: map()]

  @doc """
  Records a new audit entry for `action` on `resource_type`/`resource_id`.
  Chains the entry to the most recent entry via SHA-256.
  """
  @spec record(String.t(), String.t(), String.t(), record_opts()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def record(action, resource_type, resource_id, opts \\ [])
      when is_binary(action) and is_binary(resource_type) and is_binary(resource_id) do
    previous_hash = fetch_latest_hash()
    actor_id = Keyword.get(opts, :actor_id, "system")
    metadata = Keyword.get(opts, :metadata, %{})

    attrs = %{
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      actor_id: actor_id,
      metadata: metadata,
      previous_hash: previous_hash,
      occurred_at: DateTime.utc_now()
    }

    attrs_with_hash = Map.put(attrs, :entry_hash, compute_hash(attrs))

    %Entry{}
    |> Entry.changeset(attrs_with_hash)
    |> Repo.insert()
  end

  @doc "Returns audit entries for a specific resource, newest first."
  @spec entries_for(String.t(), String.t()) :: [Entry.t()]
  def entries_for(resource_type, resource_id)
      when is_binary(resource_type) and is_binary(resource_id) do
    Entry
    |> where([e], e.resource_type == ^resource_type and e.resource_id == ^resource_id)
    |> order_by([e], desc: e.occurred_at)
    |> Repo.all()
  end

  @doc """
  Verifies the integrity of the audit chain for a given resource.
  Returns `{:ok, :intact}` or `{:error, {:tampered, entry_id}}`.
  """
  @spec verify_chain(String.t(), String.t()) ::
          {:ok, :intact} | {:error, {:tampered, pos_integer()}}
  def verify_chain(resource_type, resource_id) do
    entries =
      Entry
      |> where([e], e.resource_type == ^resource_type and e.resource_id == ^resource_id)
      |> order_by([e], asc: e.occurred_at)
      |> Repo.all()

    check_chain_integrity(entries)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec fetch_latest_hash() :: String.t()
  defp fetch_latest_hash do
    case Repo.one(from(e in Entry, order_by: [desc: e.occurred_at], limit: 1, select: e.entry_hash)) do
      nil -> "genesis"
      hash -> hash
    end
  end

  @spec compute_hash(map()) :: String.t()
  defp compute_hash(attrs) do
    content = "#{attrs.action}:#{attrs.resource_type}:#{attrs.resource_id}:#{attrs.actor_id}:#{attrs.previous_hash}"
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @spec check_chain_integrity([Entry.t()]) ::
          {:ok, :intact} | {:error, {:tampered, pos_integer()}}
  defp check_chain_integrity([]), do: {:ok, :intact}

  defp check_chain_integrity(entries) do
    result =
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        expected =
          compute_hash(%{
            action: entry.action,
            resource_type: entry.resource_type,
            resource_id: entry.resource_id,
            actor_id: entry.actor_id,
            previous_hash: entry.previous_hash
          })

        if Plug.Crypto.secure_compare(expected, entry.entry_hash) do
          {:cont, :ok}
        else
          {:halt, {:tampered, entry.id}}
        end
      end)

    case result do
      :ok -> {:ok, :intact}
      {:tampered, id} -> {:error, {:tampered, id}}
    end
  end
end

defmodule Compliance.Audit.ChainVerification do
  @moduledoc "Result type for audit chain verification."
  defstruct [:status, :tampered_entry_id]
  @type t :: %__MODULE__{status: :intact | :tampered, tampered_entry_id: pos_integer() | nil}
end
```
