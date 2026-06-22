```elixir
defmodule Releases.ChangelogTracker do
  @moduledoc """
  Tracks application release versions, changelogs, and schema migrations
  associated with each deployment. Allows the support team to query what
  changed between any two versions and which database migrations ran with
  a given release. All version strings are validated against semantic
  versioning rules before insertion.
  """

  alias Releases.{Changelog, MigrationRecord, Repo}
  alias Ecto.Multi
  import Ecto.Query

  @type version :: binary()
  @type change_type :: :feature | :fix | :improvement | :breaking | :deprecation | :security

  @type entry_attrs :: %{
          required(:version) => version(),
          required(:type) => change_type(),
          required(:summary) => binary(),
          optional(:detail) => binary(),
          optional(:breaking) => boolean(),
          optional(:migration_versions) => [binary()]
        }

  @semver_regex ~r/^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?(\+[a-zA-Z0-9.]+)?$/

  @doc """
  Records a new changelog entry for `version`. Validates the version string,
  checks for uniqueness, and associates any listed migration versions.
  Returns `{:ok, entry}` or `{:error, reason}`.
  """
  @spec record(entry_attrs()) :: {:ok, Changelog.t()} | {:error, term()}
  def record(%{version: version} = attrs) when is_binary(version) do
    with :ok <- validate_semver(version),
         :ok <- assert_version_unique(version),
         {:ok, entry} <- insert_entry(attrs) do
      {:ok, entry}
    end
  end

  @doc """
  Returns all changelog entries between `from_version` and `to_version`,
  inclusive and ordered by version number ascending.
  """
  @spec changes_between(version(), version()) ::
          {:ok, [Changelog.t()]} | {:error, :invalid_range | :version_not_found}
  def changes_between(from_version, to_version)
      when is_binary(from_version) and is_binary(to_version) do
    with :ok <- validate_semver(from_version),
         :ok <- validate_semver(to_version),
         :ok <- validate_range_order(from_version, to_version) do
      entries =
        Changelog
        |> where([c], c.version >= ^from_version and c.version <= ^to_version)
        |> order_by([c], asc: c.version)
        |> Repo.all()

      {:ok, entries}
    end
  end

  @doc """
  Returns the changelog entry for `version`, or `{:error, :not_found}`.
  """
  @spec fetch(version()) :: {:ok, Changelog.t()} | {:error, :not_found | :invalid_version}
  def fetch(version) when is_binary(version) do
    with :ok <- validate_semver(version) do
      case Repo.get_by(Changelog, version: version) do
        nil -> {:error, :not_found}
        entry -> {:ok, entry}
      end
    end
  end

  @doc """
  Returns all breaking changes introduced between `from_version` and `to_version`.
  Used by upgrade guides to generate migration notes automatically.
  """
  @spec breaking_changes_between(version(), version()) ::
          {:ok, [Changelog.t()]} | {:error, term()}
  def breaking_changes_between(from_version, to_version) do
    with {:ok, entries} <- changes_between(from_version, to_version) do
      breaking = Enum.filter(entries, & &1.breaking)
      {:ok, breaking}
    end
  end

  @doc """
  Returns all database migration versions that ran with `version`.
  """
  @spec migrations_for(version()) :: {:ok, [binary()]} | {:error, term()}
  def migrations_for(version) when is_binary(version) do
    with {:ok, entry} <- fetch(version) do
      migration_versions =
        MigrationRecord
        |> where([m], m.changelog_id == ^entry.id)
        |> select([m], m.migration_version)
        |> order_by([m], asc: m.migration_version)
        |> Repo.all()

      {:ok, migration_versions}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_semver(version) do
    if Regex.match?(@semver_regex, version) do
      :ok
    else
      {:error, {:invalid_semver, version}}
    end
  end

  defp assert_version_unique(version) do
    case Repo.get_by(Changelog, version: version) do
      nil -> :ok
      _existing -> {:error, {:version_already_exists, version}}
    end
  end

  defp validate_range_order(from, to) do
    parsed_from = parse_version(from)
    parsed_to = parse_version(to)

    if parsed_from <= parsed_to, do: :ok, else: {:error, :invalid_range}
  end

  defp parse_version(version) do
    version
    |> String.split(~r/[-+]/)
    |> hd()
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
  end

  defp insert_entry(attrs) do
    migration_versions = Map.get(attrs, :migration_versions, [])

    Multi.new()
    |> Multi.insert(:changelog, Changelog.changeset(%Changelog{}, attrs))
    |> Multi.run(:migrations, fn repo, %{changelog: entry} ->
      records =
        Enum.map(migration_versions, fn mv ->
          %{changelog_id: entry.id, migration_version: mv,
            inserted_at: DateTime.utc_now(), updated_at: DateTime.utc_now()}
        end)

      {count, _} = repo.insert_all(MigrationRecord, records)
      {:ok, count}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{changelog: entry}} -> {:ok, entry}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end
end
```
