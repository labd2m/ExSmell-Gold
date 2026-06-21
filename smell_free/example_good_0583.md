```elixir
defmodule Platform.ChangesetDiff do
  @moduledoc """
  Extracts human-readable field-level changes from Ecto changesets.

  Produces structured diff maps suitable for audit log entries, activity
  feeds, or admin interfaces. Only changed fields are included; unchanged
  fields are omitted. Sensitive fields can be redacted per call.
  """

  @type field :: atom()
  @type change :: %{field: field(), from: term(), to: term()}
  @type diff :: [change()]
  @type diff_opts :: [redact: [field()], exclude: [field()]]

  @doc """
  Returns a list of change maps for all modified fields in `changeset`.

  Nested associations that were changed are represented as their own
  diff list under the field name.
  """
  @spec diff(Ecto.Changeset.t(), diff_opts()) :: diff()
  def diff(%Ecto.Changeset{} = changeset, opts \\ []) do
    redact = Keyword.get(opts, :redact, [])
    exclude = Keyword.get(opts, :exclude, [])

    changeset.changes
    |> Enum.reject(fn {field, _} -> field in exclude end)
    |> Enum.map(fn {field, new_value} ->
      old_value = Map.get(changeset.data, field)

      if field in redact do
        %{field: field, from: "[REDACTED]", to: "[REDACTED]"}
      else
        %{field: field, from: format_value(old_value), to: format_value(new_value)}
      end
    end)
    |> Enum.reject(&no_change?/1)
  end

  @doc """
  Returns a map of `field => {from, to}` tuples for changed fields.
  Convenient for pattern matching in audit log handlers.
  """
  @spec diff_map(Ecto.Changeset.t(), diff_opts()) :: %{optional(field()) => {term(), term()}}
  def diff_map(%Ecto.Changeset{} = changeset, opts \\ []) do
    changeset
    |> diff(opts)
    |> Map.new(fn %{field: field, from: from, to: to} -> {field, {from, to}} end)
  end

  @doc """
  Returns `true` if the changeset modified any of the given `fields`.
  """
  @spec changed?(Ecto.Changeset.t(), [field()] | field()) :: boolean()
  def changed?(%Ecto.Changeset{changes: changes}, fields) when is_list(fields) do
    Enum.any?(fields, &Map.has_key?(changes, &1))
  end

  def changed?(%Ecto.Changeset{changes: changes}, field) when is_atom(field) do
    Map.has_key?(changes, field)
  end

  @doc "Returns the old and new values for a specific field, or `nil` if unchanged."
  @spec field_change(Ecto.Changeset.t(), field()) :: {term(), term()} | nil
  def field_change(%Ecto.Changeset{} = changeset, field) when is_atom(field) do
    case Map.get(changeset.changes, field) do
      nil -> nil
      new_value -> {Map.get(changeset.data, field), new_value}
    end
  end

  @doc "Returns a formatted human-readable summary of all changes."
  @spec summary(Ecto.Changeset.t(), diff_opts()) :: String.t()
  def summary(%Ecto.Changeset{} = changeset, opts \\ []) do
    changes = diff(changeset, opts)

    if changes == [] do
      "No changes"
    else
      changes
      |> Enum.map_join("; ", fn %{field: f, from: from, to: to} ->
        "#{f}: #{inspect(from)} → #{inspect(to)}"
      end)
    end
  end

  defp format_value(%Ecto.Changeset{} = nested), do: diff(nested)
  defp format_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_value(%Date{} = d), do: Date.to_iso8601(d)
  defp format_value(value), do: value

  defp no_change?(%{from: same, to: same}), do: true
  defp no_change?(_), do: false
end
```
