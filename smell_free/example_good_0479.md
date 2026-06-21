```elixir
defmodule Maintenance.Window do
  @moduledoc """
  Defines a named scheduled maintenance period.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          message: String.t()
        }

  defstruct [:name, :starts_at, :ends_at, :message]

  @spec active?(t(), DateTime.t()) :: boolean()
  def active?(%__MODULE__{starts_at: from, ends_at: to}, now) do
    DateTime.compare(now, from) != :lt and DateTime.compare(now, to) != :gt
  end

  @spec upcoming?(t(), DateTime.t()) :: boolean()
  def upcoming?(%__MODULE__{starts_at: from}, now) do
    DateTime.compare(now, from) == :lt
  end
end

defmodule Maintenance.Schedule do
  @moduledoc """
  Manages a collection of maintenance windows and answers queries about
  current and upcoming scheduled downtime.
  """

  use GenServer

  alias Maintenance.Window

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec add_window(Window.t()) :: :ok
  def add_window(%Window{} = window) do
    GenServer.call(__MODULE__, {:add, window})
  end

  @spec remove_window(String.t()) :: :ok
  def remove_window(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:remove, name})
  end

  @spec currently_active?() :: boolean()
  def currently_active? do
    GenServer.call(__MODULE__, {:active?, DateTime.utc_now()})
  end

  @spec active_window() :: {:ok, Window.t()} | {:error, :none}
  def active_window do
    GenServer.call(__MODULE__, {:active_window, DateTime.utc_now()})
  end

  @spec upcoming_windows(pos_integer()) :: [Window.t()]
  def upcoming_windows(limit \\ 5) do
    GenServer.call(__MODULE__, {:upcoming, DateTime.utc_now(), limit})
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{windows: []}}

  @impl GenServer
  def handle_call({:add, window}, _from, state) do
    {:reply, :ok, %{state | windows: [window | state.windows]}}
  end

  def handle_call({:remove, name}, _from, state) do
    filtered = Enum.reject(state.windows, &(&1.name == name))
    {:reply, :ok, %{state | windows: filtered}}
  end

  def handle_call({:active?, now}, _from, state) do
    active = Enum.any?(state.windows, &Window.active?(&1, now))
    {:reply, active, state}
  end

  def handle_call({:active_window, now}, _from, state) do
    result =
      case Enum.find(state.windows, &Window.active?(&1, now)) do
        nil -> {:error, :none}
        w -> {:ok, w}
      end

    {:reply, result, state}
  end

  def handle_call({:upcoming, now, limit}, _from, state) do
    upcoming =
      state.windows
      |> Enum.filter(&Window.upcoming?(&1, now))
      |> Enum.sort_by(& &1.starts_at, DateTime)
      |> Enum.take(limit)

    {:reply, upcoming, state}
  end
end

defmodule Maintenance.Plug do
  @moduledoc """
  Serves `503 Service Unavailable` during an active maintenance window.
  """

  @behaviour Plug

  alias Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Conn{} = conn, _opts) do
    case Maintenance.Schedule.active_window() do
      {:ok, window} ->
        body = Jason.encode!(%{error: "Service under maintenance", message: window.message})

        conn
        |> Conn.put_resp_header("retry-after", "3600")
        |> Conn.put_resp_content_type("application/json")
        |> Conn.send_resp(503, body)
        |> Conn.halt()

      {:error, :none} ->
        conn
    end
  end
end
```
