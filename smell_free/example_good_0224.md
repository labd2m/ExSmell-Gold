```elixir
defmodule MyApp.Catalog.SearchRequest do
  @moduledoc """
  A validated, typed value object representing a product search request.
  Decoding and validation are performed through an Ecto embedded schema
  rather than raw map access, giving field-level error messages suitable
  for API responses without requiring a database-backed schema.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  @valid_sorts [:relevance, :price_asc, :price_desc, :newest, :bestseller]

  embedded_schema do
    field :query, :string
    field :category_slug, :string
    field :min_price_cents, :integer
    field :max_price_cents, :integer
    field :available_only, :boolean, default: false
    field :sort_by, Ecto.Enum, values: @valid_sorts, default: :relevance
    field :page, :integer, default: 1
    field :page_size, :integer, default: 20
    field :tags, {:array, :string}, default: []
  end

  @type t :: %__MODULE__{
          query: String.t() | nil,
          category_slug: String.t() | nil,
          min_price_cents: pos_integer() | nil,
          max_price_cents: pos_integer() | nil,
          available_only: boolean(),
          sort_by: atom(),
          page: pos_integer(),
          page_size: pos_integer(),
          tags: [String.t()]
        }

  @doc """
  Parses and validates `params`, returning `{:ok, request}` or
  `{:error, changeset}` with field-level error details.
  """
  @spec from_params(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def from_params(params) when is_map(params) do
    changeset = build_changeset(params)

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      {:error, changeset}
    end
  end

  @doc "Returns a normalized search request for empty/browse queries."
  @spec default() :: t()
  def default do
    {:ok, req} = from_params(%{})
    req
  end

  @spec build_changeset(map()) :: Ecto.Changeset.t()
  defp build_changeset(params) do
    %__MODULE__{}
    |> cast(params, [
      :query, :category_slug, :min_price_cents, :max_price_cents,
      :available_only, :sort_by, :page, :page_size, :tags
    ])
    |> validate_length(:query, max: 200)
    |> validate_length(:category_slug, max: 100)
    |> validate_number(:min_price_cents, greater_than: 0)
    |> validate_number(:max_price_cents, greater_than: 0)
    |> validate_price_range()
    |> validate_number(:page, greater_than: 0, less_than_or_equal_to: 10_000)
    |> validate_number(:page_size, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_length(:tags, max: 10)
  end

  @spec validate_price_range(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  defp validate_price_range(changeset) do
    min = get_field(changeset, :min_price_cents)
    max = get_field(changeset, :max_price_cents)

    if is_integer(min) and is_integer(max) and max < min do
      add_error(changeset, :max_price_cents, "must be greater than or equal to min_price_cents")
    else
      changeset
    end
  end
end
```
