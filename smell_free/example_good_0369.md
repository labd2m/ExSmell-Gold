```elixir
defmodule Content.SlugRegistry do
  @moduledoc """
  Maintains a registry of reserved and active slugs across content types
  in a GenServer-backed ETS table. Ensures no two content items of the
  same type share a slug. The registry is the single source of truth for
  slug uniqueness so content context modules delegate reservation here
  instead of performing separate database uniqueness queries.
  """

  use GenServer

  @type content_type :: String.t()
  @type slug :: String.t()
  @type owner_id :: String.t()
  @type registry_key :: {content_type(), slug()}

  @table :slug_registry

  @doc "Starts the slug registry and loads active slugs from the database."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attempts to reserve `slug` for `content_type` on behalf of `owner_id`.
  Returns `{:error, :already_taken}` when the slug is in use.
  """
  @spec reserve(content_type(), slug(), owner_id()) ::
          :ok | {:error, :already_taken}
  def reserve(content_type, slug, owner_id)
      when is_binary(content_type) and is_binary(slug) and is_binary(owner_id) do
    GenServer.call(__MODULE__, {:reserve, content_type, slug, owner_id})
  end

  @doc "Releases `slug` for `content_type`, making it available for reuse."
  @spec release(content_type(), slug()) :: :ok
  def release(content_type, slug)
      when is_binary(content_type) and is_binary(slug) do
    GenServer.cast(__MODULE__, {:release, content_type, slug})
  end

  @doc "Returns true when `slug` is already taken for `content_type`."
  @spec taken?(content_type(), slug()) :: boolean()
  def taken?(content_type, slug) do
    :ets.member(@table, {content_type, slug})
  end

  @doc "Returns the owner ID for a reserved slug, or `nil` if not reserved."
  @spec owner(content_type(), slug()) :: owner_id() | nil
  def owner(content_type, slug) do
    case :ets.lookup(@table, {content_type, slug}) do
      [{_key, owner_id}] -> owner_id
      [] -> nil
    end
  end

  @doc "Returns the count of currently reserved slugs."
  @spec reserved_count() :: non_neg_integer()
  def reserved_count, do: :ets.info(@table, :size)

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    preload = Keyword.get(opts, :preload, true)
    if preload, do: load_from_database()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:reserve, content_type, slug, owner_id}, _from, state) do
    key = {content_type, slug}

    if :ets.member(@table, key) do
      {:reply, {:error, :already_taken}, state}
    else
      :ets.insert(@table, {key, owner_id})
      {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_cast({:release, content_type, slug}, state) do
    :ets.delete(@table, {content_type, slug})
    {:noreply, state}
  end

  defp load_from_database do
    import Ecto.Query

    from(c in "content_items", select: {c.content_type, c.slug, c.id})
    |> MyApp.Repo.all()
    |> Enum.each(fn {content_type, slug, id} ->
      :ets.insert(@table, {{content_type, slug}, id})
    end)
  rescue
    _ -> :ok
  end
end
```
