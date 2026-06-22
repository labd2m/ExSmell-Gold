```elixir
defmodule Attachments.Attachment do
  @moduledoc """
  Represents a file attachment associated with any domain entity through a
  polymorphic association. The `owner_type` and `owner_id` pair identifies
  the parent entity, while `purpose` disambiguates multiple attachments
  on the same entity (e.g. `:profile_photo` vs `:identity_document`).
  Retrieval helpers scope queries by both owner identity and purpose so
  callers never need to construct the polymorphic filter manually.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Attachments.{Attachment, Repo}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @purposes [:profile_photo, :identity_document, :invoice_pdf,
             :product_image, :support_attachment, :export_file]

  schema "attachments" do
    field :owner_type, :string
    field :owner_id, :binary_id
    field :purpose, Ecto.Enum, values: @purposes
    field :filename, :string
    field :content_type, :string
    field :size_bytes, :integer
    field :storage_key, :string
    field :storage_url, :string
    field :metadata, :map, default: %{}
    timestamps()
  end

  @type t :: %__MODULE__{}

  @type owner :: %{__struct__: module(), id: binary()}
  @type purpose :: unquote(Enum.reduce(@purposes, &{:|, [], [&1, &2]}))

  @doc """
  Builds a changeset for a new attachment record. The `owner` struct is used
  to derive the `owner_type` from its module name so call sites stay free of
  string literals.
  """
  @spec changeset(t(), owner(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = attachment, owner, attrs) do
    owner_type = owner.__struct__ |> Module.split() |> List.last()

    attachment
    |> cast(attrs, [:purpose, :filename, :content_type, :size_bytes, :storage_key, :storage_url, :metadata])
    |> put_change(:owner_type, owner_type)
    |> put_change(:owner_id, owner.id)
    |> validate_required([:purpose, :filename, :content_type, :size_bytes, :storage_key, :owner_type, :owner_id])
    |> validate_inclusion(:purpose, @purposes)
    |> validate_number(:size_bytes, greater_than: 0)
  end

  @doc """
  Returns all attachments for `owner` with the given `purpose`.
  """
  @spec for_owner(owner(), purpose()) :: [t()]
  def for_owner(owner, purpose) do
    owner_type = owner.__struct__ |> Module.split() |> List.last()

    Attachment
    |> where([a], a.owner_type == ^owner_type and a.owner_id == ^owner.id and a.purpose == ^purpose)
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns the most recently created attachment for `owner` with the given `purpose`.
  """
  @spec latest_for_owner(owner(), purpose()) :: {:ok, t()} | {:error, :not_found}
  def latest_for_owner(owner, purpose) do
    owner_type = owner.__struct__ |> Module.split() |> List.last()

    result =
      Attachment
      |> where([a], a.owner_type == ^owner_type and a.owner_id == ^owner.id and a.purpose == ^purpose)
      |> order_by([a], desc: a.inserted_at)
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      attachment -> {:ok, attachment}
    end
  end

  @doc """
  Creates and persists a new attachment for `owner`.
  """
  @spec attach(owner(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def attach(owner, attrs) when is_map(attrs) do
    %Attachment{}
    |> changeset(owner, attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes all attachments for `owner` with the given `purpose`.
  Returns the count of deleted records.
  """
  @spec detach_all(owner(), purpose()) :: {:ok, non_neg_integer()}
  def detach_all(owner, purpose) do
    owner_type = owner.__struct__ |> Module.split() |> List.last()

    {count, _} =
      Attachment
      |> where([a], a.owner_type == ^owner_type and a.owner_id == ^owner.id and a.purpose == ^purpose)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Returns `true` when `owner` has at least one attachment for `purpose`.
  """
  @spec attached?(owner(), purpose()) :: boolean()
  def attached?(owner, purpose) do
    owner_type = owner.__struct__ |> Module.split() |> List.last()

    Attachment
    |> where([a], a.owner_type == ^owner_type and a.owner_id == ^owner.id and a.purpose == ^purpose)
    |> Repo.exists?()
  end
end
```
