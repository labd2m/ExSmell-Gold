```elixir
defmodule Projections.UserReadModel do
  @moduledoc """
  Maintains a denormalised read model for user profiles by consuming
  domain events from a PubSub topic. Each event handler updates only the
  fields it owns, making the projection resilient to schema evolution.
  The read model is stored in ETS for sub-millisecond query performance.
  """

  use GenServer

  require Logger

  @table :user_read_model
  @topic "domain:events"

  @type user_id :: String.t()
  @type profile :: %{
          user_id: user_id(),
          email: String.t() | nil,
          display_name: String.t() | nil,
          role: String.t() | nil,
          confirmed: boolean(),
          last_sign_in: DateTime.t() | nil
        }

  @doc "Starts the projection worker and subscribes to the domain events topic."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the read model for `user_id`, or `{:error, :not_found}`."
  @spec fetch(user_id()) :: {:ok, profile()} | {:error, :not_found}
  def fetch(user_id) when is_binary(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, profile}] -> {:ok, profile}
      [] -> {:error, :not_found}
    end
  end

  @doc "Returns all profiles matching a keyword search on display_name or email."
  @spec search(String.t()) :: [profile()]
  def search(term) when is_binary(term) do
    lower = String.downcase(term)

    :ets.tab2list(@table)
    |> Enum.map(fn {_id, profile} -> profile end)
    |> Enum.filter(fn p ->
      String.contains?(String.downcase(p.email || ""), lower) or
        String.contains?(String.downcase(p.display_name || ""), lower)
    end)
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    Phoenix.PubSub.subscribe(MyApp.PubSub, @topic)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info({:domain_event, %{"type" => "user.registered", "payload" => p}}, state) do
    profile = %{user_id: p["user_id"], email: p["email"], display_name: p["display_name"],
                role: p["role"] || "viewer", confirmed: false, last_sign_in: nil}
    :ets.insert(@table, {p["user_id"], profile})
    {:noreply, state}
  end

  def handle_info({:domain_event, %{"type" => "user.confirmed", "payload" => p}}, state) do
    update_profile(p["user_id"], fn profile -> %{profile | confirmed: true} end)
    {:noreply, state}
  end

  def handle_info({:domain_event, %{"type" => "user.signed_in", "payload" => p}}, state) do
    update_profile(p["user_id"], fn profile ->
      %{profile | last_sign_in: parse_datetime(p["signed_in_at"])}
    end)
    {:noreply, state}
  end

  def handle_info({:domain_event, %{"type" => "user.role_changed", "payload" => p}}, state) do
    update_profile(p["user_id"], fn profile -> %{profile | role: p["role"]} end)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp update_profile(user_id, fun) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, profile}] -> :ets.insert(@table, {user_id, fun.(profile)})
      [] -> Logger.warning("[UserReadModel] unknown user_id in event: #{user_id}")
    end
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
```
