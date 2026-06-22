```elixir
defmodule Content.SlugResolver do
  @moduledoc """
  Generates unique URL slugs for content records and resolves them back to IDs.

  Collision handling appends a numeric suffix and retries. All slug
  generation logic is isolated in pure helper functions, keeping the
  database-aware code confined to the context boundary.
  """

  import Ecto.Query

  alias Content.Repo
  alias Content.SlugResolver.{SlugRecord, Normaliser}

  @max_suffix 9_999

  @doc """
  Generates a unique slug for the given title within a resource type namespace.

  Returns `{:ok, slug}` or `{:error, reason}` if a unique slug cannot be found.
  """
  @spec generate(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def generate(title, resource_type)
      when is_binary(title) and title != "" and is_binary(resource_type) do
    base = Normaliser.slugify(title)
    find_unique(base, resource_type, nil)
  end

  def generate(_, _), do: {:error, "title and resource_type are required"}

  @doc """
  Persists a slug mapping for a resource.
  """
  @spec register(String.t(), String.t(), String.t()) :: {:ok, SlugRecord.t()} | {:error, term()}
  def register(slug, resource_id, resource_type)
      when is_binary(slug) and is_binary(resource_id) and is_binary(resource_type) do
    %SlugRecord{}
    |> SlugRecord.changeset(%{slug: slug, resource_id: resource_id, resource_type: resource_type})
    |> Repo.insert()
  end

  @doc """
  Resolves a slug to its resource ID within a resource type namespace.
  """
  @spec resolve(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def resolve(slug, resource_type)
      when is_binary(slug) and is_binary(resource_type) do
    SlugRecord
    |> where([s], s.slug == ^slug and s.resource_type == ^resource_type)
    |> select([s], s.resource_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      resource_id -> {:ok, resource_id}
    end
  end

  @doc """
  Retires a slug when its resource is deleted or renamed.
  """
  @spec retire(String.t(), String.t()) :: :ok | {:error, :not_found}
  def retire(slug, resource_type) when is_binary(slug) and is_binary(resource_type) do
    deleted =
      SlugRecord
      |> where([s], s.slug == ^slug and s.resource_type == ^resource_type)
      |> Repo.delete_all()

    case deleted do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  end

  defp find_unique(base, resource_type, suffix) do
    candidate = build_candidate(base, suffix)

    exists =
      SlugRecord
      |> where([s], s.slug == ^candidate and s.resource_type == ^resource_type)
      |> Repo.exists?()

    if exists do
      next_suffix = (suffix || 0) + 1

      if next_suffix > @max_suffix do
        {:error, "could not find unique slug for #{base} after #{@max_suffix} attempts"}
      else
        find_unique(base, resource_type, next_suffix)
      end
    else
      {:ok, candidate}
    end
  end

  defp build_candidate(base, nil), do: base
  defp build_candidate(base, suffix), do: "#{base}-#{suffix}"
end

defmodule Content.SlugResolver.Normaliser do
  @moduledoc "Pure slug normalisation functions."

  @spec slugify(String.t()) :: String.t()
  def slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9\s-]/u, "")
    |> String.replace(~r/[\s]+/, "-")
    |> String.replace(~r/-{2,}/, "-")
    |> String.trim("-")
  end
end

defmodule Content.SlugResolver.SlugRecord do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  schema "content_slugs" do
    field :slug, :string
    field :resource_id, :string
    field :resource_type, :string
    timestamps()
  end

  @type t :: %__MODULE__{}

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:slug, :resource_id, :resource_type])
    |> validate_required([:slug, :resource_id, :resource_type])
    |> unique_constraint([:slug, :resource_type])
  end
end
```
