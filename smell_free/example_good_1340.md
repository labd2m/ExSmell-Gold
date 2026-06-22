```elixir
defmodule Deployment.CanarySplitter do
  @moduledoc """
  Routes traffic between stable and canary service variants based on
  configurable percentage weights.

  Assignment is deterministic per request identifier (e.g. user ID or session
  token), ensuring a given identity always routes to the same variant within
  a deployment window. Weights are adjusted through the GenServer API.
  """

  use GenServer

  alias Deployment.CanarySplitter.{SplitConfig, VariantAssignment}

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns the variant (`:stable` or `:canary`) assigned to a given identity.
  """
  @spec assign(String.t()) :: {:ok, VariantAssignment.t()} | {:error, String.t()}
  def assign(identity_key) when is_binary(identity_key) do
    GenServer.call(__MODULE__, {:assign, identity_key})
  end

  @doc """
  Updates the canary traffic percentage.

  `canary_pct` must be an integer between 0 and 100 inclusive.
  """
  @spec set_canary_percentage(non_neg_integer()) :: :ok | {:error, String.t()}
  def set_canary_percentage(pct) when is_integer(pct) and pct >= 0 and pct <= 100 do
    GenServer.call(__MODULE__, {:set_pct, pct})
  end

  def set_canary_percentage(_), do: {:error, "percentage must be an integer between 0 and 100"}

  @doc """
  Returns the current split configuration.
  """
  @spec current_config() :: SplitConfig.t()
  def current_config, do: GenServer.call(__MODULE__, :config)

  @doc """
  Pauses canary traffic by setting the canary percentage to zero.
  """
  @spec pause_canary() :: :ok
  def pause_canary, do: GenServer.cast(__MODULE__, :pause)

  @impl GenServer
  def init(opts) do
    canary_pct = Keyword.get(opts, :canary_pct, 0)
    salt = Keyword.get(opts, :salt, "default")
    config = SplitConfig.new(canary_pct, salt)
    {:ok, config}
  end

  @impl GenServer
  def handle_call({:assign, identity_key}, _from, config) do
    bucket = compute_bucket(identity_key, config.salt)
    variant = if bucket < config.canary_pct, do: :canary, else: :stable
    assignment = VariantAssignment.new(identity_key, variant, bucket, config.canary_pct)
    {:reply, {:ok, assignment}, config}
  end

  def handle_call({:set_pct, pct}, _from, config) do
    {:reply, :ok, %{config | canary_pct: pct}}
  end

  def handle_call(:config, _from, config) do
    {:reply, config, config}
  end

  @impl GenServer
  def handle_cast(:pause, config) do
    {:noreply, %{config | canary_pct: 0}}
  end

  defp compute_bucket(identity_key, salt) do
    <<bucket::unsigned-integer-32, _::binary>> =
      :crypto.hash(:sha256, "#{salt}:#{identity_key}")

    rem(bucket, 100)
  end
end

defmodule Deployment.CanarySplitter.SplitConfig do
  @moduledoc false

  @enforce_keys [:canary_pct, :salt]
  defstruct [:canary_pct, :salt]

  @type t :: %__MODULE__{canary_pct: non_neg_integer(), salt: String.t()}

  @spec new(non_neg_integer(), String.t()) :: t()
  def new(canary_pct, salt) when is_integer(canary_pct) and is_binary(salt) do
    %__MODULE__{canary_pct: canary_pct, salt: salt}
  end
end

defmodule Deployment.CanarySplitter.VariantAssignment do
  @moduledoc "Result of a traffic split assignment for a given identity."

  @enforce_keys [:identity_key, :variant, :bucket, :canary_pct_at_assignment]
  defstruct [:identity_key, :variant, :bucket, :canary_pct_at_assignment]

  @type variant :: :stable | :canary
  @type t :: %__MODULE__{
          identity_key: String.t(),
          variant: variant(),
          bucket: non_neg_integer(),
          canary_pct_at_assignment: non_neg_integer()
        }

  @spec new(String.t(), variant(), non_neg_integer(), non_neg_integer()) :: t()
  def new(identity_key, variant, bucket, pct) do
    %__MODULE__{
      identity_key: identity_key,
      variant: variant,
      bucket: bucket,
      canary_pct_at_assignment: pct
    }
  end

  @spec canary?(t()) :: boolean()
  def canary?(%__MODULE__{variant: :canary}), do: true
  def canary?(_), do: false
end
```
