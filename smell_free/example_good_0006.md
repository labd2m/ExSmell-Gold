# File: `example_good_06.md`

```elixir
defmodule Auth.TokenStore do
  @moduledoc """
  Centralized in-memory store for short-lived authentication tokens.

  An `Agent` backs the store, but all interactions are mediated through
  this module's public API. No external module calls `Agent.get/2` or
  `Agent.update/2` directly on this process.
  """

  use Agent

  @type token :: String.t()
  @type user_id :: String.t()
  @type ttl_seconds :: pos_integer()

  @type entry :: %{
          user_id: user_id(),
          expires_at: DateTime.t()
        }

  @doc false
  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc """
  Issues a new cryptographically random token for `user_id` with
  the given time-to-live in seconds.

  Returns the token string, which must be kept secret by the caller.
  """
  @spec issue(user_id(), ttl_seconds()) :: token()
  def issue(user_id, ttl_seconds)
      when is_binary(user_id) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    token = generate_token()
    entry = build_entry(user_id, ttl_seconds)
    Agent.update(__MODULE__, &Map.put(&1, token, entry))
    token
  end

  @doc """
  Validates a token and returns the associated user ID when the token
  is present and has not yet expired.

  Returns `{:ok, user_id}`, `{:error, :expired}`, or `{:error, :invalid}`.
  """
  @spec verify(token()) :: {:ok, user_id()} | {:error, :expired | :invalid}
  def verify(token) when is_binary(token) do
    Agent.get(__MODULE__, &Map.get(&1, token))
    |> evaluate_entry()
  end

  @doc """
  Immediately revokes a token by removing it from the store.

  Returns `:ok` unconditionally.
  """
  @spec revoke(token()) :: :ok
  def revoke(token) when is_binary(token) do
    Agent.update(__MODULE__, &Map.delete(&1, token))
  end

  @doc """
  Removes all expired tokens from the store.

  Returns the count of entries that were purged.
  """
  @spec purge_expired() :: non_neg_integer()
  def purge_expired do
    now = DateTime.utc_now()

    Agent.get_and_update(__MODULE__, fn store ->
      {live, expired} =
        Map.split_with(store, fn {_token, entry} ->
          DateTime.compare(entry.expires_at, now) == :gt
        end)

      {map_size(expired), live}
    end)
  end

  @doc """
  Returns the total number of tokens currently held in the store,
  including any that may have already expired but not yet purged.
  """
  @spec count() :: non_neg_integer()
  def count do
    Agent.get(__MODULE__, &map_size/1)
  end

  @doc """
  Returns `true` when a token exists in the store, regardless of expiry.
  """
  @spec exists?(token()) :: boolean()
  def exists?(token) when is_binary(token) do
    Agent.get(__MODULE__, &Map.has_key?(&1, token))
  end

  defp evaluate_entry(nil), do: {:error, :invalid}

  defp evaluate_entry(%{user_id: uid, expires_at: expires_at}) do
    case DateTime.compare(expires_at, DateTime.utc_now()) do
      :gt -> {:ok, uid}
      _ -> {:error, :expired}
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp build_entry(user_id, ttl_seconds) do
    %{
      user_id: user_id,
      expires_at: DateTime.add(DateTime.utc_now(), ttl_seconds, :second)
    }
  end
end
```
