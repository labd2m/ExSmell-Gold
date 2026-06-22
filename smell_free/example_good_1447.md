```elixir
defmodule MyApp.Ops.AlertSilencer do
  @moduledoc """
  Manages maintenance windows during which alerts from specified sources
  are suppressed. Silences are stored in ETS for fast per-alert lookups
  and persisted to the database for durability. The silencer evaluates
  the current wall-clock time against each active silence window before
  letting an alert through to the notification system.
  """

  use GenServer

  require Logger

  alias MyApp.Repo
  alias MyApp.Ops.AlertSilence

  import Ecto.Query, warn: false

  @table __MODULE__
  @reload_interval_ms 60_000

  @type silence_id :: String.t()
  @type matcher :: %{optional(:source) => String.t(), optional(:label) => String.t()}

  @doc "Starts the alert silencer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns `true` when `alert` is currently silenced by any active window.
  `alert` is a map with at minimum a `:source` key.
  """
  @spec silenced?(map()) :: boolean()
  def silenced?(alert) when is_map(alert) do
    now = DateTime.utc_now()

    @table
    |> :ets.tab2list()
    |> Enum.any?(fn {_id, silence} ->
      active_now?(silence, now) and matches?(silence.matcher, alert)
    end)
  end

  @doc "Creates a silence window and activates it immediately."
  @spec create(matcher(), DateTime.t(), DateTime.t(), String.t()) ::
          {:ok, AlertSilence.t()} | {:error, Ecto.Changeset.t()}
  def create(matcher, starts_at, ends_at, created_by)
      when is_map(matcher) and is_binary(created_by) do
    result =
      %AlertSilence{}
      |> AlertSilence.changeset(%{
        matcher: matcher,
        starts_at: starts_at,
        ends_at: ends_at,
        created_by: created_by
      })
      |> Repo.insert()

    case result do
      {:ok, silence} ->
        :ets.insert(@table, {silence.id, silence})
        {:ok, silence}

      error ->
        error
    end
  end

  @doc "Expires a silence window before its scheduled end time."
  @spec expire(silence_id()) :: :ok | {:error, :not_found}
  def expire(silence_id) when is_binary(silence_id) do
    case Repo.get(AlertSilence, silence_id) do
      nil ->
        {:error, :not_found}

      silence ->
        silence
        |> AlertSilence.changeset(%{ends_at: DateTime.utc_now()})
        |> Repo.update()

        :ets.delete(@table, silence_id)
        Logger.info("alert_silence_expired", id: silence_id)
        :ok
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    reload_silences()
    schedule_reload()
    {:ok, %{}}
  end

  @impl GenServer
  def handle_info(:reload, state) do
    reload_silences()
    schedule_reload()
    {:noreply, state}
  end

  @spec reload_silences() :: :ok
  defp reload_silences do
    now = DateTime.utc_now()

    active =
      AlertSilence
      |> where([s], s.starts_at <= ^now and s.ends_at > ^now)
      |> Repo.all()

    :ets.delete_all_objects(@table)
    Enum.each(active, fn s -> :ets.insert(@table, {s.id, s}) end)
    :ok
  end

  @spec active_now?(AlertSilence.t(), DateTime.t()) :: boolean()
  defp active_now?(silence, now) do
    DateTime.compare(silence.starts_at, now) != :gt and
      DateTime.compare(silence.ends_at, now) == :gt
  end

  @spec matches?(matcher(), map()) :: boolean()
  defp matches?(matcher, alert) do
    Enum.all?(matcher, fn {key, value} ->
      Map.get(alert, key) == value
    end)
  end

  @spec schedule_reload() :: reference()
  defp schedule_reload, do: Process.send_after(self(), :reload, @reload_interval_ms)
end
```
