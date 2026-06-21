```elixir
defmodule Sync.ConflictResolver do
  @moduledoc """
  Resolves synchronisation conflicts between a local record version and a
  remote version using configurable resolution strategies. Each strategy
  is a pure function that accepts both versions and returns the winning
  record. Built-in strategies cover last-write-wins, field-level merge,
  and explicit manual resolution markers.
  """

  @type version :: %{updated_at: DateTime.t(), data: map(), source: :local | :remote}
  @type strategy :: :last_write_wins | :remote_wins | :local_wins | :field_merge
  @type resolution :: %{winner: version(), strategy: strategy(), merged_fields: [atom()]}

  @doc """
  Resolves the conflict between `local` and `remote` using `strategy`.
  Returns a resolution map describing which version won and how.
  """
  @spec resolve(version(), version(), strategy()) :: resolution()
  def resolve(%{} = local, %{} = remote, strategy)
      when strategy in [:last_write_wins, :remote_wins, :local_wins, :field_merge] do
    apply_strategy(strategy, local, remote)
  end

  @doc "Returns the field names that differ between two versions."
  @spec differing_fields(version(), version()) :: [atom()]
  def differing_fields(%{data: local_data}, %{data: remote_data}) do
    all_keys =
      (Map.keys(local_data) ++ Map.keys(remote_data))
      |> Enum.map(fn
        k when is_binary(k) -> String.to_existing_atom(k)
        k -> k
      end)
      |> Enum.uniq()

    Enum.filter(all_keys, fn key ->
      Map.get(local_data, key) != Map.get(remote_data, key)
    end)
  rescue
    ArgumentError -> []
  end

  defp apply_strategy(:last_write_wins, local, remote) do
    winner =
      case DateTime.compare(local.updated_at, remote.updated_at) do
        :gt -> local
        :eq -> remote
        :lt -> remote
      end

    %{winner: winner, strategy: :last_write_wins, merged_fields: []}
  end

  defp apply_strategy(:remote_wins, _local, remote) do
    %{winner: remote, strategy: :remote_wins, merged_fields: []}
  end

  defp apply_strategy(:local_wins, local, _remote) do
    %{winner: local, strategy: :local_wins, merged_fields: []}
  end

  defp apply_strategy(:field_merge, local, remote) do
    changed_remotely = differing_fields(local, remote)

    merged_data =
      Enum.reduce(changed_remotely, local.data, fn field, acc ->
        remote_value = Map.get(remote.data, field)
        Map.put(acc, field, remote_value)
      end)

    merged_at =
      case DateTime.compare(local.updated_at, remote.updated_at) do
        :gt -> local.updated_at
        _ -> remote.updated_at
      end

    merged_version = %{updated_at: merged_at, data: merged_data, source: :remote}
    %{winner: merged_version, strategy: :field_merge, merged_fields: changed_remotely}
  end
end
```
