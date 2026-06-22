```elixir
defmodule OAuth2.ManagedToken do
  @moduledoc false

  @type t :: %__MODULE__{
          access_token: String.t(),
          token_type: String.t(),
          expires_at: integer(),
          refresh_token: String.t() | nil,
          scope: String.t() | nil
        }

  defstruct [:access_token, :token_type, :expires_at, :refresh_token, :scope]

  @spec valid?(t(), pos_integer()) :: boolean()
  def valid?(%__MODULE__{expires_at: exp}, buffer_seconds \\ 30) do
    System.system_time(:second) + buffer_seconds < exp
  end
end

defmodule OAuth2.TokenRefresher do
  @moduledoc """
  Transparently maintains a valid OAuth2 access token, refreshing it
  before expiry without requiring callers to manage the token lifecycle.

  Token refreshes are serialised through the GenServer so that concurrent
  callers waiting for a fresh token do not trigger redundant network requests.
  A configurable `expiry_buffer_seconds` controls how far in advance of
  expiry a refresh is triggered, preventing token expiry mid-request.
  """

  use GenServer

  alias OAuth2.ManagedToken

  @type refresh_fn :: (String.t() -> {:ok, ManagedToken.t()} | {:error, term()})

  @type opts :: [
          initial_token: ManagedToken.t() | nil,
          refresh_fn: refresh_fn(),
          expiry_buffer_seconds: pos_integer()
        ]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get_token() :: {:ok, String.t()} | {:error, term()}
  def get_token do
    GenServer.call(__MODULE__, :get_token, 15_000)
  end

  @spec invalidate() :: :ok
  def invalidate do
    GenServer.cast(__MODULE__, :invalidate)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      token: Keyword.get(opts, :initial_token),
      refresh_fn: Keyword.fetch!(opts, :refresh_fn),
      expiry_buffer: Keyword.get(opts, :expiry_buffer_seconds, 60),
      refreshing: false,
      waiters: []
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_token, from, state) do
    cond do
      state.token != nil and ManagedToken.valid?(state.token, state.expiry_buffer) ->
        {:reply, {:ok, state.token.access_token}, state}

      state.refreshing ->
        {:noreply, %{state | waiters: [from | state.waiters]}}

      true ->
        send(self(), :do_refresh)
        {:noreply, %{state | refreshing: true, waiters: [from | state.waiters]}}
    end
  end

  @impl GenServer
  def handle_cast(:invalidate, state) do
    {:noreply, %{state | token: nil}}
  end

  @impl GenServer
  def handle_info(:do_refresh, state) do
    refresh_token = state.token && state.token.refresh_token

    result =
      if refresh_token do
        state.refresh_fn.(refresh_token)
      else
        {:error, :no_refresh_token}
      end

    {reply, new_token} =
      case result do
        {:ok, %ManagedToken{} = token} -> {{:ok, token.access_token}, token}
        {:error, reason} -> {{:error, reason}, state.token}
      end

    Enum.each(state.waiters, &GenServer.reply(&1, reply))

    {:noreply, %{state | token: new_token, refreshing: false, waiters: []}}
  end
end
```
