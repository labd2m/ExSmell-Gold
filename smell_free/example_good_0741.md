```elixir
defmodule OAuth2.AuthState do
  @moduledoc false

  @type t :: %__MODULE__{
          state_token: String.t(),
          code_verifier: String.t(),
          redirect_uri: String.t(),
          scopes: [String.t()],
          created_at: integer(),
          expires_at: integer()
        }

  defstruct [:state_token, :code_verifier, :redirect_uri, :scopes, :created_at, :expires_at]
end

defmodule OAuth2.FlowManager do
  @moduledoc """
  Manages the server-side state for an OAuth2 Authorization Code flow
  with PKCE and CSRF protection.

  When a user initiates login, `initiate/2` generates a random `state`
  token and a PKCE `code_verifier`, stores both server-side, and returns
  the data needed to build the authorization URL. When the provider
  redirects back, `complete/2` verifies the `state` parameter matches
  the session, retrieves the `code_verifier` for the token exchange, and
  consumes the entry to prevent replay.
  """

  use GenServer

  alias OAuth2.AuthState

  @default_ttl_seconds 600
  @state_bytes 32
  @verifier_bytes 32

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec initiate(String.t(), keyword()) :: {:ok, map()}
  def initiate(redirect_uri, opts \\ []) when is_binary(redirect_uri) do
    state_token = generate_token()
    code_verifier = generate_token()
    scopes = Keyword.get(opts, :scopes, [])
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    now = System.monotonic_time(:second)

    auth_state = %AuthState{
      state_token: state_token,
      code_verifier: code_verifier,
      redirect_uri: redirect_uri,
      scopes: scopes,
      created_at: now,
      expires_at: now + ttl
    }

    GenServer.call(__MODULE__, {:store, state_token, auth_state})

    code_challenge =
      :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)

    {:ok,
     %{
       state: state_token,
       code_challenge: code_challenge,
       code_challenge_method: "S256",
       redirect_uri: redirect_uri,
       scopes: scopes
     }}
  end

  @spec complete(String.t()) ::
          {:ok, %{code_verifier: String.t(), redirect_uri: String.t()}}
          | {:error, :invalid_state | :expired}
  def complete(state_token) when is_binary(state_token) do
    GenServer.call(__MODULE__, {:consume, state_token})
  end

  @impl GenServer
  def init(_opts) do
    schedule_sweep()
    {:ok, %{pending: %{}}}
  end

  @impl GenServer
  def handle_call({:store, token, auth_state}, _from, state) do
    {:reply, :ok, %{state | pending: Map.put(state.pending, token, auth_state)}}
  end

  def handle_call({:consume, token}, _from, state) do
    now = System.monotonic_time(:second)

    {reply, updated_pending} =
      case Map.fetch(state.pending, token) do
        {:ok, %AuthState{expires_at: exp}} when exp < now ->
          {{:error, :expired}, Map.delete(state.pending, token)}

        {:ok, %AuthState{} = auth_state} ->
          result = %{code_verifier: auth_state.code_verifier, redirect_uri: auth_state.redirect_uri}
          {{:ok, result}, Map.delete(state.pending, token)}

        :error ->
          {{:error, :invalid_state}, state.pending}
      end

    {:reply, reply, %{state | pending: updated_pending}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:second)
    pruned = Map.reject(state.pending, fn {_, v} -> v.expires_at < now end)
    schedule_sweep()
    {:noreply, %{state | pending: pruned}}
  end

  defp generate_token do
    :crypto.strong_rand_bytes(@state_bytes) |> Base.url_encode64(padding: false)
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, 60_000)
end
```
