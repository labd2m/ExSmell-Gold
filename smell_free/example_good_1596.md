```elixir
defmodule Reports.Schedule do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Persisted configuration for a recurring report delivery schedule.
  """

  @type frequency :: :daily | :weekly | :monthly

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          name: String.t(),
          report_type: String.t(),
          frequency: frequency(),
          recipient_emails: [String.t()],
          parameters: map(),
          active: boolean(),
          last_run_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "report_schedules" do
    field :name, :string
    field :report_type, :string
    field :frequency, Ecto.Enum, values: [:daily, :weekly, :monthly]
    field :recipient_emails, {:array, :string}, default: []
    field :parameters, :map, default: %{}
    field :active, :boolean, default: true
    field :last_run_at, :utc_datetime
    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:name, :report_type, :frequency, :recipient_emails, :parameters, :active])
    |> validate_required([:name, :report_type, :frequency, :recipient_emails])
    |> validate_length(:recipient_emails, min: 1)
  end
end

defmodule Reports.Scheduler do
  use GenServer

  import Ecto.Query

  alias Reports.Schedule
  alias MyApp.Repo

  @moduledoc """
  Periodically scans active report schedules and dispatches due reports
  via a configurable generator module. Tracks last run time to avoid
  duplicate deliveries on process restart.
  """

  @poll_interval_ms 60_000 * 5

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    generator = Keyword.fetch!(opts, :generator)
    send(self(), :poll)
    {:ok, %{generator: generator}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    run_due_schedules(state.generator)
    Process.send_after(self(), :poll, @poll_interval_ms)
    {:noreply, state}
  end

  defp run_due_schedules(generator) do
    due_schedules()
    |> Enum.each(fn schedule ->
      Task.Supervisor.start_child(
        Reports.TaskSupervisor,
        fn -> dispatch_schedule(schedule, generator) end
      )
    end)
  end

  defp due_schedules do
    now = DateTime.utc_now()

    Schedule
    |> where([s], s.active == true)
    |> Repo.all()
    |> Enum.filter(&due?(&1, now))
  end

  defp due?(%Schedule{frequency: :daily, last_run_at: nil}, _now), do: true
  defp due?(%Schedule{frequency: :weekly, last_run_at: nil}, _now), do: true
  defp due?(%Schedule{frequency: :monthly, last_run_at: nil}, _now), do: true

  defp due?(%Schedule{frequency: :daily, last_run_at: last}, now) do
    DateTime.diff(now, last, :hour) >= 24
  end

  defp due?(%Schedule{frequency: :weekly, last_run_at: last}, now) do
    DateTime.diff(now, last, :hour) >= 168
  end

  defp due?(%Schedule{frequency: :monthly, last_run_at: last}, now) do
    DateTime.diff(now, last, :day) >= 28
  end

  defp dispatch_schedule(schedule, generator) do
    case generator.generate(schedule.report_type, schedule.parameters) do
      {:ok, report_data} ->
        Enum.each(schedule.recipient_emails, fn email ->
          generator.deliver(email, schedule.name, report_data)
        end)

        now = DateTime.utc_now() |> DateTime.truncate(:second)
        Repo.update!(Ecto.Changeset.change(schedule, last_run_at: now))

      {:error, _reason} ->
        :ok
    end
  end
end
```
