**File:** `example_good_1734.md`

```elixir
defmodule FeatureFlags.Flag do
  @moduledoc "Represents a single feature flag definition and its rollout configuration."

  @enforce_keys [:name, :enabled, :rollout_percentage]
  defstruct [:name, :description, :enabled, :rollout_percentage, :allowlist, :denylist]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          enabled: boolean(),
          rollout_percentage: non_neg_integer(),
          allowlist: [String.t()],
          denylist: [String.t()]
        }

  @spec new(String.t(), keyword()) :: t()
  def new(name, opts \\ []) do
    %__MODULE__{
      name: name,
      description: Keyword.get(opts, :description),
      enabled: Keyword.get(opts, :enabled, false),
      rollout_percentage: Keyword.get(opts, :rollout_percentage, 0),
      allowlist: Keyword.get(opts, :allowlist, []),
      denylist: Keyword.get(opts, :denylist, [])
    }
  end
end

defmodule FeatureFlags.Evaluator do
  @moduledoc """
  Evaluates whether a feature flag is active for a given subject identifier.
  Evaluation follows a priority chain: denylist, allowlist, global toggle, rollout percentage.
  """

  alias FeatureFlags.Flag

  @spec enabled?(Flag.t(), String.t()) :: boolean()
  def enabled?(%Flag{} = flag, subject_id) when is_binary(subject_id) do
    cond do
      subject_in_denylist?(flag, subject_id) -> false
      subject_in_allowlist?(flag, subject_id) -> true
      not flag.enabled -> false
      true -> within_rollout?(flag, subject_id)
    end
  end

  defp subject_in_denylist?(%Flag{denylist: list}, id), do: id in list
  defp subject_in_allowlist?(%Flag{allowlist: list}, id), do: id in list

  defp within_rollout?(%Flag{rollout_percentage: 100}, _id), do: true
  defp within_rollout?(%Flag{rollout_percentage: 0}, _id), do: false

  defp within_rollout?(%Flag{name: name, rollout_percentage: pct}, id) do
    hash = :erlang.phash2("#{name}:#{id}", 100)
    hash < pct
  end
end

defmodule FeatureFlags.Store do
  @moduledoc """
  Manages the in-memory registry of feature flags backed by an Agent.
  Provides a structured API for flag registration, updates, and lookups.
  """

  use Agent

  alias FeatureFlags.Flag

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    initial_flags =
      opts
      |> Keyword.get(:flags, [])
      |> Map.new(fn %Flag{name: name} = flag -> {name, flag} end)

    Agent.start_link(fn -> initial_flags end, name: __MODULE__)
  end

  @spec put(Flag.t()) :: :ok
  def put(%Flag{name: name} = flag) do
    Agent.update(__MODULE__, &Map.put(&1, name, flag))
  end

  @spec get(String.t()) :: {:ok, Flag.t()} | {:error, :not_found}
  def get(name) when is_binary(name) do
    case Agent.get(__MODULE__, &Map.get(&1, name)) do
      nil -> {:error, :not_found}
      flag -> {:ok, flag}
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(name) when is_binary(name) do
    Agent.update(__MODULE__, &Map.delete(&1, name))
  end

  @spec all() :: [Flag.t()]
  def all do
    Agent.get(__MODULE__, &Map.values/1)
  end
end

defmodule FeatureFlags do
  @moduledoc """
  Public interface for checking feature flag status for a given subject.
  """

  alias FeatureFlags.{Evaluator, Store}

  @spec enabled?(String.t(), String.t()) :: boolean()
  def enabled?(flag_name, subject_id) when is_binary(flag_name) and is_binary(subject_id) do
    case Store.get(flag_name) do
      {:ok, flag} -> Evaluator.enabled?(flag, subject_id)
      {:error, :not_found} -> false
    end
  end

  @spec flag_names() :: [String.t()]
  def flag_names do
    Store.all() |> Enum.map(& &1.name)
  end

  @spec register(String.t(), keyword()) :: :ok
  def register(name, opts \\ []) when is_binary(name) do
    Store.put(FeatureFlags.Flag.new(name, opts))
  end
end
```
