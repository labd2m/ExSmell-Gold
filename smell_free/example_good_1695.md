```elixir
defmodule Content.SlugRegistry do
  @moduledoc """
  Maintains a registry of unique URL slugs for published content entries.
  Provides conflict detection and automatic suffix generation for duplicates.
  """

  use GenServer

  @type slug :: String.t()
  @type content_id :: String.t()
  @type state :: %{slugs: %{slug() => content_id()}, reverse: %{content_id() => slug()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{slugs: %{}, reverse: %{}}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec register(content_id(), String.t()) :: {:ok, slug()} | {:error, String.t()}
  def register(content_id, title)
      when is_binary(content_id) and is_binary(title) do
    GenServer.call(__MODULE__, {:register, content_id, title})
  end

  @spec lookup_by_slug(slug()) :: {:ok, content_id()} | {:error, :not_found}
  def lookup_by_slug(slug) when is_binary(slug) do
    GenServer.call(__MODULE__, {:lookup_slug, slug})
  end

  @spec lookup_by_id(content_id()) :: {:ok, slug()} | {:error, :not_found}
  def lookup_by_id(content_id) when is_binary(content_id) do
    GenServer.call(__MODULE__, {:lookup_id, content_id})
  end

  @spec release(content_id()) :: :ok
  def release(content_id) when is_binary(content_id) do
    GenServer.cast(__MODULE__, {:release, content_id})
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:register, content_id, title}, _from, state) do
    base_slug = slugify(title)
    final_slug = find_available_slug(base_slug, state.slugs, 0)
    new_state = %{
      slugs: Map.put(state.slugs, final_slug, content_id),
      reverse: Map.put(state.reverse, content_id, final_slug)
    }
    {:reply, {:ok, final_slug}, new_state}
  end

  def handle_call({:lookup_slug, slug}, _from, state) do
    case Map.get(state.slugs, slug) do
      nil -> {:reply, {:error, :not_found}, state}
      id -> {:reply, {:ok, id}, state}
    end
  end

  def handle_call({:lookup_id, content_id}, _from, state) do
    case Map.get(state.reverse, content_id) do
      nil -> {:reply, {:error, :not_found}, state}
      slug -> {:reply, {:ok, slug}, state}
    end
  end

  @impl GenServer
  def handle_cast({:release, content_id}, state) do
    case Map.get(state.reverse, content_id) do
      nil ->
        {:noreply, state}

      slug ->
        new_state = %{
          slugs: Map.delete(state.slugs, slug),
          reverse: Map.delete(state.reverse, content_id)
        }
        {:noreply, new_state}
    end
  end

  @spec find_available_slug(String.t(), map(), non_neg_integer()) :: slug()
  defp find_available_slug(base, slugs, 0) do
    if Map.has_key?(slugs, base),
      do: find_available_slug(base, slugs, 1),
      else: base
  end

  defp find_available_slug(base, slugs, n) do
    candidate = "#{base}-#{n}"
    if Map.has_key?(slugs, candidate),
      do: find_available_slug(base, slugs, n + 1),
      else: candidate
  end

  @spec slugify(String.t()) :: slug()
  defp slugify(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/[\s_]+/, "-")
    |> String.trim("-")
  end
end
```
