```elixir
defmodule FeatureFlags.Flag do
  @moduledoc false

  @type value ::
          boolean()
          | {:percentage_rollout, 0..100}
          | {:allowlist, [String.t()]}

  @type t :: %__MODULE__{
          name: atom(),
          value: value(),
          description: String.t()
        }

  defstruct [:name, :value, description: ""]
end

defmodule FeatureFlags.Evaluator do
  @moduledoc false

  alias FeatureFlags.Flag

  @spec evaluate(Flag.value(), String.t() | nil) :: boolean()
  def evaluate(true, _context), do: true
  def evaluate(false, _context), do: false

  def evaluate({:percentage_rollout, pct}, nil) do
    :rand.uniform(100) <= pct
  end

  def evaluate({:percentage_rollout, pct}, context) when is_binary(context) do
    :erlang.phash2(context, 100) < pct
  end

  def evaluate({:allowlist, ids}, context) when is_binary(context) do
    context in ids
  end

  def evaluate({:allowlist, _ids}, nil), do: false
end

defmodule FeatureFlags.Store do
  @moduledoc """
  An ETS-backed feature flag registry with lock-free concurrent reads.

  Flag mutations are serialized through the GenServer to prevent write
  conflicts, while reads go directly to the public ETS table so they
  never block on a single process. Percentage-rollout flags use a
  deterministic hash of the context string so the same identity always
  receives the same answer for a given rollout percentage.
  """

  use GenServer

  alias FeatureFlags.{Evaluator, Flag}

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec enabled?(atom(), String.t() | nil) :: boolean()
  def enabled?(name, context \\ nil) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, flag}] -> Evaluator.evaluate(flag.value, context)
      [] -> false
    end
  end

  @spec set(atom(), Flag.value(), String.t()) :: :ok
  def set(name, value, description \\ "") when is_atom(name) do
    flag = %Flag{name: name, value: value, description: description}
    GenServer.call(__MODULE__, {:set, flag})
  end

  @spec delete(atom()) :: :ok
  def delete(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:delete, name})
  end

  @spec get(atom()) :: {:ok, Flag.t()} | {:error, :not_found}
  def get(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, flag}] -> {:ok, flag}
      [] -> {:error, :not_found}
    end
  end

  @spec all() :: [Flag.t()]
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, flag} -> flag end)
    |> Enum.sort_by(& &1.name)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:set, %Flag{name: name} = flag}, _from, state) do
    :ets.insert(@table, {name, flag})
    {:reply, :ok, state}
  end

  def handle_call({:delete, name}, _from, state) do
    :ets.delete(@table, name)
    {:reply, :ok, state}
  end
end
```
