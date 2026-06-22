```elixir
defmodule Versioning.Snapshot do
  @moduledoc """
  An immutable point-in-time snapshot of a versioned document's content.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          document_id: String.t(),
          version: pos_integer(),
          content: String.t(),
          author_id: String.t(),
          message: String.t() | nil,
          created_at: DateTime.t()
        }

  defstruct [:id, :document_id, :version, :content, :author_id, :message, :created_at]
end

defmodule Versioning.Document do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Versioning.Snapshot
  alias MyApp.Repo

  @moduledoc """
  Provides append-only version history for text documents.
  Each save creates a new immutable snapshot rather than mutating existing data.
  """

  schema "document_snapshots" do
    field :document_id, :binary_id
    field :version, :integer
    field :content, :string
    field :author_id, :binary_id
    field :message, :string
    field :created_at, :utc_datetime
  end

  @spec save(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Ecto.Changeset.t()}
  def save(document_id, content, author_id, opts \\ [])
      when is_binary(document_id) and is_binary(content) and is_binary(author_id) do
    message = Keyword.get(opts, :message)
    next_version = next_version_for(document_id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      document_id: document_id,
      version: next_version,
      content: content,
      author_id: author_id,
      message: message,
      created_at: now
    }

    case %__MODULE__{} |> cast(attrs, [:document_id, :version, :content, :author_id, :message, :created_at])
         |> validate_required([:document_id, :version, :content, :author_id, :created_at])
         |> Repo.insert() do
      {:ok, row} -> {:ok, to_snapshot(row)}
      {:error, cs} -> {:error, cs}
    end
  end

  @spec history(String.t(), keyword()) :: [Snapshot.t()]
  def history(document_id, opts \\ []) when is_binary(document_id) do
    limit = Keyword.get(opts, :limit, 50)

    __MODULE__
    |> where([s], s.document_id == ^document_id)
    |> order_by([s], desc: s.version)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&to_snapshot/1)
  end

  @spec at_version(String.t(), pos_integer()) :: {:ok, Snapshot.t()} | {:error, :not_found}
  def at_version(document_id, version)
      when is_binary(document_id) and is_integer(version) and version > 0 do
    case Repo.get_by(__MODULE__, document_id: document_id, version: version) do
      nil -> {:error, :not_found}
      row -> {:ok, to_snapshot(row)}
    end
  end

  @spec latest(String.t()) :: {:ok, Snapshot.t()} | {:error, :not_found}
  def latest(document_id) when is_binary(document_id) do
    result =
      __MODULE__
      |> where([s], s.document_id == ^document_id)
      |> order_by([s], desc: s.version)
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      row -> {:ok, to_snapshot(row)}
    end
  end

  defp next_version_for(document_id) do
    current =
      __MODULE__
      |> where([s], s.document_id == ^document_id)
      |> select([s], max(s.version))
      |> Repo.one()

    (current || 0) + 1
  end

  defp to_snapshot(row) do
    %Snapshot{
      id: to_string(row.id),
      document_id: to_string(row.document_id),
      version: row.version,
      content: row.content,
      author_id: to_string(row.author_id),
      message: row.message,
      created_at: row.created_at
    }
  end
end
```
