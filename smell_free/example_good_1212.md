```elixir
defmodule MyApp.Content.RevisionDiff do
  @moduledoc """
  Computes a structured diff between two revisions of a content document.
  Beyond raw text changes, the diff identifies added and removed inline
  media references, tag changes, and metadata field mutations — giving
  editors a semantic change summary rather than a raw line diff.
  """

  alias MyApp.Content.{Revision, DiffReport}

  @type field_change :: %{field: atom(), before: term(), after: term()}

  @doc """
  Produces a `DiffReport` comparing `old_rev` to `new_rev`.
  The report includes text changes, media mutations, tag deltas, and
  metadata field changes.
  """
  @spec compute(Revision.t(), Revision.t()) :: DiffReport.t()
  def compute(%Revision{} = old_rev, %Revision{} = new_rev) do
    %DiffReport{
      old_revision_id: old_rev.id,
      new_revision_id: new_rev.id,
      text_changed: old_rev.body != new_rev.body,
      added_media: added_media(old_rev, new_rev),
      removed_media: removed_media(old_rev, new_rev),
      added_tags: added_tags(old_rev, new_rev),
      removed_tags: removed_tags(old_rev, new_rev),
      metadata_changes: metadata_changes(old_rev, new_rev),
      is_empty: empty_diff?(old_rev, new_rev)
    }
  end

  @doc "Returns `true` when the two revisions are semantically identical."
  @spec identical?(Revision.t(), Revision.t()) :: boolean()
  def identical?(old_rev, new_rev) do
    compute(old_rev, new_rev).is_empty
  end

  @spec added_media(Revision.t(), Revision.t()) :: [String.t()]
  defp added_media(old_rev, new_rev) do
    old_ids = extract_media_ids(old_rev.body)
    new_ids = extract_media_ids(new_rev.body)
    MapSet.difference(new_ids, old_ids) |> MapSet.to_list()
  end

  @spec removed_media(Revision.t(), Revision.t()) :: [String.t()]
  defp removed_media(old_rev, new_rev) do
    old_ids = extract_media_ids(old_rev.body)
    new_ids = extract_media_ids(new_rev.body)
    MapSet.difference(old_ids, new_ids) |> MapSet.to_list()
  end

  @spec extract_media_ids(String.t() | nil) :: MapSet.t()
  defp extract_media_ids(nil), do: MapSet.new()

  defp extract_media_ids(body) do
    ~r/media:\/\/([a-z0-9\-]+)/
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  @spec added_tags(Revision.t(), Revision.t()) :: [String.t()]
  defp added_tags(old_rev, new_rev) do
    (new_rev.tags -- old_rev.tags)
  end

  @spec removed_tags(Revision.t(), Revision.t()) :: [String.t()]
  defp removed_tags(old_rev, new_rev) do
    (old_rev.tags -- new_rev.tags)
  end

  @spec metadata_changes(Revision.t(), Revision.t()) :: [field_change()]
  defp metadata_changes(old_rev, new_rev) do
    [:title, :slug, :excerpt, :author_id, :status]
    |> Enum.flat_map(fn field ->
      old_val = Map.get(old_rev, field)
      new_val = Map.get(new_rev, field)

      if old_val != new_val do
        [%{field: field, before: old_val, after: new_val}]
      else
        []
      end
    end)
  end

  @spec empty_diff?(Revision.t(), Revision.t()) :: boolean()
  defp empty_diff?(old_rev, new_rev) do
    report = compute(old_rev, new_rev)

    not report.text_changed and
      report.added_media == [] and
      report.removed_media == [] and
      report.added_tags == [] and
      report.removed_tags == [] and
      report.metadata_changes == []
  end
end
```
