```elixir
defmodule Flags.Flag do
  @moduledoc """
  An immutable value object describing a feature flag and its targeting rules.
  """

  @enforce_keys [:key, :enabled]
  defstruct [:key, :enabled, :rollout_percentage, :allowed_actor_ids, :description]

  @type t :: %__MODULE__{
          key: String.t(),
          enabled: boolean(),
          rollout_percentage: non_neg_integer() | nil,
          allowed_actor_ids: list(String.t()) | nil,
          description: String.t() | nil
        }

  @spec new(String.t(), boolean(), keyword()) :: t()
  def new(key, enabled, opts \\ []) when is_binary(key) and is_boolean(enabled) do
    %__MODULE__{
      key: key,
      enabled: enabled,
      rollout_percentage: Keyword.get(opts, :rollout_percentage),
      allowed_actor_ids: Keyword.get(opts, :allowed_actor_ids),
      description: Keyword.get(opts, :description)
    }
  end
end

defmodule Flags.Evaluator do
  @moduledoc """
  Pure flag evaluation logic. Determines whether a flag is active for a given
  actor by checking global enablement, explicit allow-lists, and percentage
  rollout buckets. No side effects — evaluation depends only on the flag struct
  and the actor ID.
  """

  alias Flags.Flag

  @spec enabled?(Flag.t(), String.t()) :: boolean()
  def enabled?(%Flag{enabled: false}, _actor_id), do: false

  def enabled?(%Flag{enabled: true, allowed_actor_ids: [_ | _] = ids}, actor_id)
      when is_binary(actor_id) do
    actor_id in ids
  end

  def enabled?(%Flag{enabled: true, rollout_percentage: pct}, actor_id)
      when is_integer(pct) and pct >= 0 and pct <= 100 and is_binary(actor_id) do
    actor_bucket(actor_id) < pct
  end

  def enabled?(%Flag{enabled: true}, _actor_id), do: true

  defp actor_bucket(actor_id) do
    :erlang.phash2(actor_id, 100)
  end
end

defmodule Flags.Store do
  @moduledoc """
  ETS-backed store for feature flags. All mutations go through this module's
  public API. Reads are fully concurrent via `:read_concurrency`.
  """

  use GenServer

  alias Flags.Flag

  @table_name :flags_ets_store

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(Flag.t()) :: :ok
  def put(%Flag{key: key} = flag) do
    GenServer.call(__MODULE__, {:put, key, flag})
  end

  @spec delete(String.t()) :: :ok
  def delete(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:delete, key})
  end

  @spec get(String.t()) :: {:ok, Flag.t()} | {:error, :not_found}
  def get(key) when is_binary(key) do
    case :ets.lookup(@table_name, key) do
      [{^key, flag}] -> {:ok, flag}
      [] -> {:error, :not_found}
    end
  end

  @spec enabled_for?(String.t(), String.t()) :: boolean()
  def enabled_for?(key, actor_id) when is_binary(key) and is_binary(actor_id) do
    case get(key) do
      {:ok, flag} -> Flags.Evaluator.enabled?(flag, actor_id)
      {:error, :not_found} -> false
    end
  end

  @spec all() :: list(Flag.t())
  def all do
    :ets.tab2list(@table_name) |> Enum.map(fn {_k, flag} -> flag end)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:put, key, flag}, _from, state) do
    :ets.insert(@table_name, {key, flag})
    {:reply, :ok, state}
  end

  def handle_call({:delete, key}, _from, state) do
    :ets.delete(@table_name, key)
    {:reply, :ok, state}
  end
end
```
