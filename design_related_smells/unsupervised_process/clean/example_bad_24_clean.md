```elixir
defmodule SessionServer do
  use GenServer

  @moduledoc """
  Maintains per-user authentication session state including token,
  permissions, and activity timestamps.
  """

  @session_ttl_seconds 3_600

  defstruct [:user_id, :token, :permissions, :created_at, :last_active_at, :expires_at]

  def open(user_id, %{token: token, permissions: permissions}) do
    GenServer.start(
      __MODULE__,
      %{user_id: user_id, token: token, permissions: permissions},
      name: via(user_id)
    )
  end

  def close(user_id) do
    GenServer.stop(via(user_id), :normal)
  end

  def touch(user_id) do
    GenServer.cast(via(user_id), :touch)
  end

  def fetch(user_id) do
    GenServer.call(via(user_id), :fetch)
  end

  def valid?(user_id) do
    case GenServer.call(via(user_id), :check_expiry) do
      :valid -> true
      :expired -> false
    end
  rescue
    _ -> false
  end

  defp via(user_id) do
    {:via, Registry, {SessionRegistry, user_id}}
  end

  ## Callbacks

  @impl true
  def init(%{user_id: user_id, token: token, permissions: permissions}) do
    now = DateTime.utc_now()

    state = %__MODULE__{
      user_id: user_id,
      token: token,
      permissions: permissions,
      created_at: now,
      last_active_at: now,
      expires_at: DateTime.add(now, @session_ttl_seconds, :second)
    }

    schedule_expiry()
    {:ok, state}
  end

  @impl true
  def handle_call(:fetch, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call(:check_expiry, _from, state) do
    result =
      if DateTime.compare(DateTime.utc_now(), state.expires_at) == :lt,
        do: :valid,
        else: :expired

    {:reply, result, state}
  end

  @impl true
  def handle_cast(:touch, state) do
    now = DateTime.utc_now()
    {:noreply, %{state | last_active_at: now, expires_at: DateTime.add(now, @session_ttl_seconds, :second)}}
  end

  @impl true
  def handle_info(:expire, state) do
    {:stop, :normal, state}
  end

  defp schedule_expiry do
    Process.send_after(self(), :expire, @session_ttl_seconds * 1_000)
  end
end

defmodule AuthGateway do
  @moduledoc """
  Handles user login and delegates session creation to SessionServer.
  """

  def login(user_id, credentials) do
    with {:ok, user} <- verify_credentials(user_id, credentials),
         token <- generate_token(),
         {:ok, _pid} <- SessionServer.open(user_id, %{token: token, permissions: user.permissions}) do
      {:ok, token}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_credentials(_user_id, %{password: "secret"}),
    do: {:ok, %{permissions: [:read, :write]}}

  defp verify_credentials(_user_id, _), do: {:error, :invalid_credentials}

  defp generate_token, do: Base.encode64(:crypto.strong_rand_bytes(32))
end
```
