```elixir
defmodule OAuth2.Pkce do
  @moduledoc """
  Implements the OAuth 2.0 Proof Key for Code Exchange extension (RFC 7636).

  PKCE prevents authorization code interception attacks in public clients
  such as mobile apps and SPAs. The client generates a random
  `code_verifier`, derives a `code_challenge` from it, sends the challenge
  in the authorization request, and proves possession of the original
  verifier when exchanging the code for tokens.

  Only the `S256` challenge method is supported; `plain` is intentionally
  omitted because it provides no security benefit over omitting PKCE entirely.
  """

  @min_verifier_bytes 32
  @max_verifier_bytes 96

  @type verifier :: String.t()
  @type challenge :: String.t()

  @spec generate_verifier() :: verifier()
  def generate_verifier do
    :crypto.strong_rand_bytes(@min_verifier_bytes)
    |> Base.url_encode64(padding: false)
  end

  @spec challenge_from_verifier(verifier()) :: challenge()
  def challenge_from_verifier(verifier) when is_binary(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end

  @spec verify(verifier(), challenge()) :: :ok | {:error, :invalid_verifier}
  def verify(verifier, expected_challenge)
      when is_binary(verifier) and is_binary(expected_challenge) do
    computed = challenge_from_verifier(verifier)

    if :crypto.hash_equals(computed, expected_challenge) do
      :ok
    else
      {:error, :invalid_verifier}
    end
  end

  @spec valid_verifier?(verifier()) :: boolean()
  def valid_verifier?(verifier) when is_binary(verifier) do
    byte_len = byte_size(verifier)
    String.match?(verifier, ~r/\A[A-Za-z0-9\-._~]+\z/) and
      byte_len >= @min_verifier_bytes and
      byte_len <= @max_verifier_bytes
  end

  def valid_verifier?(_), do: false
end

defmodule OAuth2.PkceSession do
  @moduledoc """
  Stores pending PKCE challenges server-side for the authorization code
  flow, keyed by a short-lived state parameter.
  """

  use GenServer

  @default_ttl_seconds 600

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec store(String.t(), OAuth2.Pkce.challenge()) :: {:ok, String.t()}
  def store(state_token, challenge) when is_binary(state_token) and is_binary(challenge) do
    GenServer.call(__MODULE__, {:store, state_token, challenge})
  end

  @spec consume(String.t(), OAuth2.Pkce.verifier()) ::
          :ok | {:error, :invalid_state | :invalid_verifier}
  def consume(state_token, verifier) when is_binary(state_token) and is_binary(verifier) do
    GenServer.call(__MODULE__, {:consume, state_token, verifier})
  end

  @impl GenServer
  def init(opts) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    {:ok, %{pending: %{}, ttl_seconds: ttl}}
  end

  @impl GenServer
  def handle_call({:store, state_token, challenge}, _from, state) do
    expires_at = System.system_time(:second) + state.ttl_seconds
    entry = %{challenge: challenge, expires_at: expires_at}
    {:reply, {:ok, state_token}, %{state | pending: Map.put(state.pending, state_token, entry)}}
  end

  def handle_call({:consume, state_token, verifier}, _from, state) do
    now = System.system_time(:second)

    {reply, updated_pending} =
      case Map.fetch(state.pending, state_token) do
        {:ok, %{challenge: challenge, expires_at: exp}} when exp > now ->
          result = OAuth2.Pkce.verify(verifier, challenge)
          {result, Map.delete(state.pending, state_token)}

        {:ok, _expired} ->
          {{:error, :invalid_state}, Map.delete(state.pending, state_token)}

        :error ->
          {{:error, :invalid_state}, state.pending}
      end

    {:reply, reply, %{state | pending: updated_pending}}
  end
end
```
