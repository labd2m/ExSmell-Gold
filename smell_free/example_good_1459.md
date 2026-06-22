```elixir
defmodule Etl.Record do
  @moduledoc """
  Represents a single normalized record produced by the ETL pipeline.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          email: String.t(),
          score: float(),
          tags: [String.t()]
        }

  defstruct [:id, :email, :score, :tags]
end

defmodule Etl.Pipeline do
  alias Etl.Record

  @moduledoc """
  A stream-based ETL pipeline that ingests raw row maps, applies
  validation, normalization, and scoring transformations, then
  emits clean `Record` structs for downstream persistence.
  """

  @required_fields ~w(id email raw_score tag_csv)

  @spec run(Enumerable.t()) :: Enumerable.t()
  def run(source) do
    source
    |> Stream.filter(&has_required_fields?/1)
    |> Stream.map(&normalize/1)
    |> Stream.filter(&valid_email?/1)
    |> Stream.map(&to_record/1)
  end

  @spec run_to_list(Enumerable.t()) :: [Record.t()]
  def run_to_list(source) do
    source
    |> run()
    |> Enum.to_list()
  end

  defp has_required_fields?(row) when is_map(row) do
    Enum.all?(@required_fields, fn field -> Map.has_key?(row, field) end)
  end

  defp normalize(row) do
    row
    |> Map.update!("email", &String.downcase(String.trim(&1)))
    |> Map.update!("raw_score", &parse_score/1)
    |> Map.update!("tag_csv", &split_tags/1)
  end

  defp valid_email?(row) do
    email = Map.fetch!(row, "email")
    String.match?(email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)
  end

  defp to_record(row) do
    %Record{
      id: Map.fetch!(row, "id"),
      email: Map.fetch!(row, "email"),
      score: Map.fetch!(row, "raw_score"),
      tags: Map.fetch!(row, "tag_csv")
    }
  end

  defp parse_score(value) when is_binary(value) do
    case Float.parse(value) do
      {score, _} -> score
      :error -> 0.0
    end
  end

  defp parse_score(value) when is_number(value), do: value / 1

  defp split_tags(csv) when is_binary(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end

defmodule Etl.Sink do
  alias Etl.Record
  alias MyApp.Repo
  alias MyApp.Schemas.ImportedRecord

  @moduledoc """
  Persists a stream of `Record` structs to the database in batches.
  Returns a summary of inserted versus rejected records.
  """

  @type summary :: %{inserted: non_neg_integer(), rejected: non_neg_integer()}

  @spec persist_stream(Enumerable.t(), keyword()) :: summary()
  def persist_stream(stream, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 100)

    stream
    |> Stream.chunk_every(batch_size)
    |> Enum.reduce(%{inserted: 0, rejected: 0}, fn batch, acc ->
      {inserted, _} = Repo.insert_all(ImportedRecord, Enum.map(batch, &to_row/1))
      rejected = length(batch) - inserted
      %{inserted: acc.inserted + inserted, rejected: acc.rejected + rejected}
    end)
  end

  defp to_row(%Record{id: id, email: email, score: score, tags: tags}) do
    %{
      external_id: id,
      email: email,
      score: score,
      tags: tags,
      imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end
end
```
