```elixir
defmodule Sync.Record do
  @moduledoc false

  @type t :: %__MODULE__{
          id: String.t(),
          version: pos_integer(),
          deleted: boolean(),
          data: map(),
          updated_at: integer()
        }

  defstruct [:id, :data, :updated_at, version: 1, deleted: false]
end

defmodule Sync.Delta do
  @moduledoc false

  @type t :: %__MODULE__{
          upserts: [Sync.Record.t()],
          deletions: [String.t()],
          server_version: pos_integer()
        }

  defstruct [upserts: [], deletions: [], server_version: 0]
end

defmodule Sync.Reconciler do
  @moduledoc """
  Computes the delta between a client's known state and the current server
  state, enabling efficient offline-first synchronisation.

  The client sends its last known `server_version`; the server responds with
  only records that changed since that version. Conflict resolution uses a
  last-write-wins strategy based on `updated_at` timestamps, with the server
  winning ties. Deleted records are tombstoned rather than removed so clients
  can sync deletions.
  """

  alias Sync.{Delta, Record}

  @type store :: [Record.t()]

  @spec compute_delta(store(), pos_integer()) :: Delta.t()
  def compute_delta(server_records, since_version) when is_integer(since_version) do
    {upserts, deletions} =
      server_records
      |> Enum.filter(&(&1.version > since_version))
      |> Enum.split_with(fn r -> not r.deleted end)

    current_version = current_version(server_records)

    %Delta{
      upserts: upserts,
      deletions: Enum.map(deletions, & &1.id),
      server_version: current_version
    }
  end

  @spec apply_client_changes(store(), [Record.t()]) ::
          {:ok, store(), [String.t()]} | {:error, term()}
  def apply_client_changes(server_records, client_changes) when is_list(client_changes) do
    server_index = Map.new(server_records, &{&1.id, &1})
    next_version = current_version(server_records) + 1

    {updated_index, rejected_ids} =
      Enum.reduce(client_changes, {server_index, []}, fn client_rec, {idx, rejected} ->
        case Map.fetch(idx, client_rec.id) do
          {:ok, server_rec} ->
            if client_rec.updated_at >= server_rec.updated_at do
              merged = %{client_rec | version: next_version}
              {Map.put(idx, client_rec.id, merged), rejected}
            else
              {idx, [client_rec.id | rejected]}
            end

          :error ->
            new_rec = %{client_rec | version: next_version}
            {Map.put(idx, client_rec.id, new_rec), rejected}
        end
      end)

    {:ok, Map.values(updated_index), Enum.reverse(rejected_ids)}
  end

  @spec merge_delta(store(), Delta.t()) :: store()
  def merge_delta(client_records, %Delta{} = delta) do
    client_index = Map.new(client_records, &{&1.id, &1})

    after_upserts =
      Enum.reduce(delta.upserts, client_index, fn server_rec, idx ->
        Map.put(idx, server_rec.id, server_rec)
      end)

    after_deletions =
      Enum.reduce(delta.deletions, after_upserts, fn id, idx ->
        Map.delete(idx, id)
      end)

    Map.values(after_deletions)
  end

  @spec current_version(store()) :: non_neg_integer()
  def current_version([]), do: 0
  def current_version(records), do: records |> Enum.map(& &1.version) |> Enum.max()
end
```
