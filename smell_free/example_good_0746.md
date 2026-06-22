# File: `example_good_746.md`

```elixir
defmodule Auth.OAuthStateManager do
  @moduledoc """
  Manages OAuth 2.0 PKCE state parameters and nonces for authorization
  flows, preventing CSRF attacks and code injection.

  Each state token is a one-time-use secret bound to the originating
  session. State tokens include the code verifier so the token exchange
  step can retrieve it without a separate lookup.
  """

  use Agent

  @state_ttl_seconds 600
  @state_bytes 32
  @verifier_bytes 32

  @type session_id :: String.t()
  @type state_token :: String.t()

  @type flow_params :: %{
          state_token: state_token(),
          code_verifier: String.t(),
          code_challenge: String.t(),
          code_challenge_method: String.t(),
          redirect_uri: String.t() | nil
        }

  @type state_entry :: %{
          session_id: session_id(),
          code_verifier: String.t(),
          redirect_uri: String.t() | nil,
          created_at: integer()
        }

  @doc false
  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Generates a new PKCE flow parameter set for the given session.

  Stores the state entry internally and returns the full set of
  parameters to include in the authorization URL.
  """
  @spec generate(session_id(), String.t() | nil) :: flow_params()
  def generate(session_id, redirect_uri \\ nil) when is_binary(session_id) do
    state_token = generate_token(@state_bytes)
    code_verifier = generate_token(@verifier_bytes)
    code_challenge = derive_code_challenge(code_verifier)

    entry = %{
      session_id: session_id,
      code_verifier: code_verifier,
      redirect_uri: redirect_uri,
      created_at: System.system_time(:second)
    }

    Agent.update(__MODULE__, &Map.put(&1, state_token, entry))

    %{
      state_token: state_token,
      code_verifier: code_verifier,
      code_challenge: code_challenge,
      code_challenge_method: "S256",
      redirect_uri: redirect_uri
    }
  end

  @doc """
  Consumes a state token, returning the associated entry if valid.

  The token is deleted on first access to enforce single-use semantics.
  Returns `{:ok, state_entry}` or `{:error, :invalid | :expired}`.
  """
  @spec consume(state_token()) :: {:ok, state_entry()} | {:error, :invalid | :expired}
  def consume(state_token) when is_binary(state_token) do
    Agent.get_and_update(__MODULE__, fn store ->
      case Map.pop(store, state_token) do
        {nil, store} -> {{:error, :invalid}, store}
        {entry, new_store} -> {evaluate_entry(entry), new_store}
      end
    end)
  end

  @doc """
  Purges expired state entries from the store.

  Returns the count of entries removed.
  """
  @spec purge_expired() :: non_neg_integer()
  def purge_expired do
    cutoff = System.system_time(:second) - @state_ttl_seconds

    Agent.get_and_update(__MODULE__, fn store ->
      {live, expired} = Map.split_with(store, fn {_token, entry} ->
        entry.created_at > cutoff
      end)

      {map_size(expired), live}
    end)
  end

  @doc """
  Returns the number of pending state entries in the store.
  """
  @spec pending_count() :: non_neg_integer()
  def pending_count do
    Agent.get(__MODULE__, &map_size/1)
  end

  @doc """
  Revokes all pending state entries for a given session ID,
  for example when the user logs out.
  """
  @spec revoke_for_session(session_id()) :: non_neg_integer()
  def revoke_for_session(session_id) when is_binary(session_id) do
    Agent.get_and_update(__MODULE__, fn store ->
      {remaining, removed} = Map.split_with(store, fn {_token, entry} ->
        entry.session_id != session_id
      end)

      {map_size(removed), remaining}
    end)
  end

  defp evaluate_entry(entry) do
    cutoff = System.system_time(:second) - @state_ttl_seconds

    if entry.created_at > cutoff do
      {:ok, entry}
    else
      {:error, :expired}
    end
  end

  defp generate_token(byte_count) do
    :crypto.strong_rand_bytes(byte_count) |> Base.url_encode64(padding: false)
  end

  defp derive_code_challenge(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end
end
```
