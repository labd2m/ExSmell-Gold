```elixir
defmodule Content.VersionedPageContext do
  @moduledoc """
  Manages versioned content pages. Each publish creates an immutable
  version record; the live page pointer is updated atomically. Editors
  can preview any version and roll back to a previous one. Draft edits
  do not affect the live version until explicitly published.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Content.{Page, PageVersion}

  @type page_id :: Ecto.UUID.t()
  @type version_number :: pos_integer()

  @doc "Creates a new page with an initial draft version."
  @spec create(String.t(), String.t(), String.t()) ::
          {:ok, Page.t()} | {:error, Ecto.Changeset.t()}
  def create(slug, title, body) when is_binary(slug) do
    Repo.transaction(fn ->
      attrs = %{slug: slug, title: title, current_version: 0, status: "draft"}

      with {:ok, page} <- %Page{} |> Page.changeset(attrs) |> Repo.insert(),
           {:ok, _version} <- create_version(page.id, 1, title, body) do
        Repo.update!(Page.changeset(page, %{current_version: 1}))
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Publishes a new version of `page`. Increments the version counter and
  marks the page as published.
  """
  @spec publish(Page.t(), String.t(), String.t()) ::
          {:ok, Page.t()} | {:error, Ecto.Changeset.t()}
  def publish(%Page{} = page, title, body) when is_binary(body) do
    Repo.transaction(fn ->
      next_version = page.current_version + 1

      with {:ok, _version} <- create_version(page.id, next_version, title, body) do
        page
        |> Page.changeset(%{current_version: next_version, status: "published"})
        |> Repo.update!()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Rolls back the live page to `version_number`."
  @spec rollback(page_id(), version_number()) ::
          {:ok, Page.t()} | {:error, :version_not_found}
  def rollback(page_id, version_number)
      when is_binary(page_id) and is_integer(version_number) do
    case fetch_version(page_id, version_number) do
      nil ->
        {:error, :version_not_found}

      _version ->
        page = Repo.get!(Page, page_id)
        {:ok, Repo.update!(Page.changeset(page, %{current_version: version_number}))}
    end
  end

  @doc "Returns the live version content for a page slug."
  @spec fetch_live(String.t()) :: {:ok, PageVersion.t()} | {:error, :not_found}
  def fetch_live(slug) when is_binary(slug) do
    query =
      from(pv in PageVersion,
        join: p in Page, on: p.id == pv.page_id,
        where: p.slug == ^slug and pv.version_number == p.current_version
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      version -> {:ok, version}
    end
  end

  @doc "Returns the full version history for `page_id` sorted newest-first."
  @spec version_history(page_id()) :: [PageVersion.t()]
  def version_history(page_id) when is_binary(page_id) do
    from(pv in PageVersion,
      where: pv.page_id == ^page_id,
      order_by: [desc: pv.version_number]
    )
    |> Repo.all()
  end

  defp create_version(page_id, version_number, title, body) do
    attrs = %{page_id: page_id, version_number: version_number, title: title, body: body}
    %PageVersion{} |> PageVersion.changeset(attrs) |> Repo.insert()
  end

  defp fetch_version(page_id, version_number) do
    Repo.get_by(PageVersion, page_id: page_id, version_number: version_number)
  end
end
```
