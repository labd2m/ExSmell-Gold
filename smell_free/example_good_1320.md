```elixir
defmodule Tenancy.Scope do
  @moduledoc """
  An explicit tenant context passed to all scoped context functions.
  Avoids process-level globals and allows multi-tenant call patterns.
  """

  @enforce_keys [:id, :slug]
  defstruct [:id, :slug, :plan, :features]

  @type t :: %__MODULE__{
          id: integer(),
          slug: String.t(),
          plan: String.t() | nil,
          features: list(atom()) | nil
        }

  @spec new(integer(), String.t(), keyword()) :: t()
  def new(id, slug, opts \\ []) when is_integer(id) and is_binary(slug) do
    %__MODULE__{
      id: id,
      slug: slug,
      plan: Keyword.get(opts, :plan),
      features: Keyword.get(opts, :features, [])
    }
  end

  @spec feature_enabled?(t(), atom()) :: boolean()
  def feature_enabled?(%__MODULE__{features: features}, feature) when is_atom(feature) do
    feature in (features || [])
  end
end

defmodule Tenancy.Articles do
  @moduledoc """
  Article management operations scoped to a specific tenant.
  Every public function accepts an explicit `Tenancy.Scope` struct so
  cross-tenant data access is structurally impossible without a valid scope.
  """

  import Ecto.Query, warn: false

  alias Tenancy.{Scope, Repo}
  alias Tenancy.Content.Article

  @type list_opts :: %{optional(:status) => String.t(), optional(:limit) => pos_integer()}

  @spec list(Scope.t(), list_opts()) :: list(Article.t())
  def list(%Scope{id: tenant_id}, opts \\ %{}) when is_map(opts) do
    Article
    |> where([a], a.tenant_id == ^tenant_id)
    |> apply_status_filter(opts)
    |> apply_limit(opts)
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  @spec get(Scope.t(), integer()) :: {:ok, Article.t()} | {:error, :not_found}
  def get(%Scope{id: tenant_id}, article_id) when is_integer(article_id) do
    case Repo.get_by(Article, id: article_id, tenant_id: tenant_id) do
      nil -> {:error, :not_found}
      article -> {:ok, article}
    end
  end

  @spec create(Scope.t(), map()) :: {:ok, Article.t()} | {:error, Ecto.Changeset.t()}
  def create(%Scope{id: tenant_id}, attrs) when is_map(attrs) do
    %Article{}
    |> Article.changeset(Map.put(attrs, :tenant_id, tenant_id))
    |> Repo.insert()
  end

  @spec publish(Scope.t(), integer()) ::
          {:ok, Article.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def publish(%Scope{} = scope, article_id) when is_integer(article_id) do
    with {:ok, article} <- get(scope, article_id) do
      article
      |> Article.changeset(%{status: "published", published_at: DateTime.utc_now()})
      |> Repo.update()
    end
  end

  @spec count(Scope.t()) :: non_neg_integer()
  def count(%Scope{id: tenant_id}) do
    Article
    |> where([a], a.tenant_id == ^tenant_id)
    |> select([a], count(a.id))
    |> Repo.one()
  end

  defp apply_status_filter(query, %{status: status}) when is_binary(status) do
    where(query, [a], a.status == ^status)
  end

  defp apply_status_filter(query, _), do: query

  defp apply_limit(query, %{limit: limit}) when is_integer(limit) and limit > 0 do
    limit(query, ^limit)
  end

  defp apply_limit(query, _), do: query
end
```
