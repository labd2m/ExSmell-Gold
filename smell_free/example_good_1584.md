```elixir
defmodule OAuth2.Token do
  @moduledoc """
  Represents an active OAuth2 access token with its associated metadata.
  """

  @type t :: %__MODULE__{
          provider: atom(),
          access_token: String.t(),
          refresh_token: String.t() | nil,
          token_type: String.t(),
          scopes: [String.t()],
          expires_at: DateTime.t()
        }

  defstruct [:provider, :access_token, :refresh_token, :token_type, :expires_at, scopes: []]

  @spec expired?(%__MODULE__{}) :: boolean()
  def expired?(%__MODULE__{expires_at: exp}) do
    DateTime.compare(DateTime.utc_now(), exp) != :lt
  end

  @spec expires_soon?(%__MODULE__{}, pos_integer()) :: boolean()
  def expires_soon?(%__MODULE__{expires_at: exp}, threshold_seconds \\ 300) do
    threshold = DateTime.add(DateTime.utc_now(), threshold_seconds, :second)
    DateTime.compare(threshold, exp) != :lt
  end
end

defmodule OAuth2.TokenManager do
  use GenServer

  alias OAuth2.Token

  @moduledoc """
  Manages the lifecycle of OAuth2 tokens per user and provider.
  Automatically refreshes tokens approaching expiry before returning them
  to callers. Tokens are stored in memory; persistence is caller-supplied.
  """

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec store(String.t(), Token.t()) :: :ok
  def store(user_id, %Token{} = token) when is_binary(user_id) do
    GenServer.cast(__MODULE__, {:store, user_id, token})
  end

  @spec fetch(String.t(), atom()) ::
          {:ok, Token.t()} | {:error, :not_found | :refresh_failed}
  def fetch(user_id, provider) when is_binary(user_id) and is_atom(provider) do
    GenServer.call(__MODULE__, {:fetch, user_id, provider})
  end

  @spec revoke(String.t(), atom()) :: :ok
  def revoke(user_id, provider) when is_binary(user_id) and is_atom(provider) do
    GenServer.cast(__MODULE__, {:revoke, user_id, provider})
  end

  @impl GenServer
  def init(opts) do
    refresher = Keyword.fetch!(opts, :refresher)
    {:ok, %{tokens: %{}, refresher: refresher}}
  end

  @impl GenServer
  def handle_cast({:store, user_id, token}, state) do
    key = {user_id, token.provider}
    {:noreply, put_in(state.tokens[key], token)}
  end

  def handle_cast({:revoke, user_id, provider}, state) do
    {:noreply, %{state | tokens: Map.delete(state.tokens, {user_id, provider})}}
  end

  @impl GenServer
  def handle_call({:fetch, user_id, provider}, _from, state) do
    key = {user_id, provider}

    case Map.fetch(state.tokens, key) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, token} when not Token.expired?(token) and not Token.expires_soon?(token) ->
        {:reply, {:ok, token}, state}

      {:ok, %Token{refresh_token: nil}} ->
        {:reply, {:error, :not_found}, Map.delete(state.tokens, key) |> then(&%{state | tokens: &1})}

      {:ok, %Token{refresh_token: rt} = token} ->
        case state.refresher.refresh(token.provider, rt) do
          {:ok, new_token} ->
            new_state = put_in(state.tokens[key], new_token)
            {:reply, {:ok, new_token}, new_state}

          {:error, _reason} ->
            {:reply, {:error, :refresh_failed}, state}
        end
    end
  end
end
```
