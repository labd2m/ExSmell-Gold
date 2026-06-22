```elixir
defmodule Dataloader.Batch do
  @moduledoc """
  A pending batch of keys to resolve against a single data source.
  """

  @type t :: %__MODULE__{
          source: module(),
          keys: [term()],
          resolve_fn: (([term()]) -> {:ok, map()} | {:error, term()})
        }

  defstruct [:source, :keys, :resolve_fn]
end

defmodule Dataloader.Loader do
  @moduledoc """
  Batches and deduplicates data fetches within a single request lifecycle.
  Callers enqueue keys during a query resolution phase; all pending batches
  are then resolved together in a single round of bulk fetches.
  """

  @type t :: %__MODULE__{
          batches: %{module() => Dataloader.Batch.t()},
          results: %{module() => map()}
        }

  defstruct batches: %{}, results: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec enqueue(t(), module(), term(), function()) :: t()
  def enqueue(%__MODULE__{} = loader, source, key, resolve_fn)
      when is_atom(source) and is_function(resolve_fn, 1) do
    batch =
      case Map.fetch(loader.batches, source) do
        {:ok, existing} -> %{existing | keys: Enum.uniq([key | existing.keys])}
        :error -> %Dataloader.Batch{source: source, keys: [key], resolve_fn: resolve_fn}
      end

    %{loader | batches: Map.put(loader.batches, source, batch)}
  end

  @spec resolve(t()) :: {:ok, t()} | {:error, {module(), term()}}
  def resolve(%__MODULE__{batches: batches} = loader) do
    results =
      Enum.reduce_while(batches, %{}, fn {source, batch}, acc ->
        case batch.resolve_fn.(batch.keys) do
          {:ok, result_map} -> {:cont, Map.put(acc, source, result_map)}
          {:error, reason} -> {:halt, {:error, {source, reason}}}
        end
      end)

    case results do
      {:error, _} = error -> error
      result_map -> {:ok, %{loader | results: result_map, batches: %{}}}
    end
  end

  @spec get(t(), module(), term()) :: {:ok, term()} | {:error, :not_loaded | :not_found}
  def get(%__MODULE__{results: results}, source, key) do
    with {:ok, source_results} <- Map.fetch(results, source),
         {:ok, value} <- Map.fetch(source_results, key) do
      {:ok, value}
    else
      :error -> {:error, :not_found}
    end
  end

  @spec loaded?(t(), module()) :: boolean()
  def loaded?(%__MODULE__{results: results}, source) do
    Map.has_key?(results, source)
  end
end

defmodule Dataloader.Sources.Users do
  @moduledoc "Batch loader for user records keyed by ID."

  alias MyApp.Accounts.User
  alias MyApp.Repo
  import Ecto.Query

  @spec load_many([String.t()]) :: {:ok, map()} | {:error, term()}
  def load_many(ids) when is_list(ids) do
    users =
      User
      |> where([u], u.id in ^ids)
      |> Repo.all()

    result = Map.new(users, fn u -> {u.id, u} end)
    {:ok, result}
  end
end
```
