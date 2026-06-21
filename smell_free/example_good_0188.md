```elixir
defmodule Storefront.CheckoutSession do
  @moduledoc """
  A GenServer that models a multi-step checkout as a stateful session.

  The checkout progresses through sequential steps: `:cart` → `:shipping`
  → `:payment` → `:review` → `:complete`. Each step transition validates
  the required data for that stage before advancing the session.
  """

  use GenServer, restart: :temporary

  @type session_id :: String.t()
  @type step :: :cart | :shipping | :payment | :review | :complete
  @type session :: %{
          id: session_id(),
          customer_id: pos_integer(),
          step: step(),
          cart: map(),
          shipping: map() | nil,
          payment: map() | nil
        }

  @step_order [:cart, :shipping, :payment, :review, :complete]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @doc "Returns the current session state."
  @spec get(session_id()) :: {:ok, session()} | {:error, :not_found}
  def get(session_id) do
    case Registry.lookup(Storefront.CheckoutRegistry, session_id) do
      [{pid, _}] -> {:ok, GenServer.call(pid, :get)}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Advances the session to the next step after validating and merging `data`.
  Returns `{:error, reason}` if required fields are missing.
  """
  @spec advance(session_id(), map()) :: {:ok, step()} | {:error, term()}
  def advance(session_id, data \\ %{}) when is_binary(session_id) do
    GenServer.call(via(session_id), {:advance, data})
  end

  @doc "Updates data at the current step without advancing."
  @spec update_data(session_id(), map()) :: :ok | {:error, term()}
  def update_data(session_id, data) when is_binary(session_id) and is_map(data) do
    GenServer.call(via(session_id), {:update_data, data})
  end

  @impl GenServer
  def init(opts) do
    session = %{
      id: Keyword.fetch!(opts, :session_id),
      customer_id: Keyword.fetch!(opts, :customer_id),
      step: :cart,
      cart: %{items: []},
      shipping: nil,
      payment: nil
    }

    {:ok, session}
  end

  @impl GenServer
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl GenServer
  def handle_call({:advance, data}, _from, %{step: current_step} = state) do
    with :ok <- validate_step(current_step, data),
         {:ok, next_step} <- next_step(current_step) do
      new_state = state |> apply_data(current_step, data) |> Map.put(:step, next_step)
      {:reply, {:ok, next_step}, new_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:update_data, data}, _from, %{step: current_step} = state) do
    case validate_step(current_step, data) do
      :ok -> {:reply, :ok, apply_data(state, current_step, data)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp validate_step(:shipping, data) do
    required = [:address_line1, :city, :country, :postal_code]
    missing = Enum.reject(required, &Map.has_key?(data, &1))
    if missing == [], do: :ok, else: {:error, {:missing_fields, missing}}
  end

  defp validate_step(:payment, data) do
    if Map.has_key?(data, :payment_method_id), do: :ok, else: {:error, {:missing_fields, [:payment_method_id]}}
  end

  defp validate_step(_step, _data), do: :ok

  defp next_step(current) do
    idx = Enum.find_index(@step_order, &(&1 == current))
    case Enum.at(@step_order, idx + 1) do
      nil -> {:error, :already_complete}
      next -> {:ok, next}
    end
  end

  defp apply_data(state, :shipping, data), do: %{state | shipping: data}
  defp apply_data(state, :payment, data), do: %{state | payment: data}
  defp apply_data(state, _step, _data), do: state

  defp via(session_id) do
    {:via, Registry, {Storefront.CheckoutRegistry, session_id}}
  end
end
```
