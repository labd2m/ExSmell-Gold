```elixir
defmodule MyApp.Support.SLATimer do
  @moduledoc """
  Tracks response-time SLA compliance for support tickets. Each ticket
  has a deadline calculated from its priority and the customer's SLA
  tier. The timer checks whether deadlines have been breached and marks
  them accordingly, enabling reports that distinguish in-SLA from
  out-of-SLA tickets.

  Deadline calculation excludes non-business hours using a configurable
  schedule, so a ticket opened at 11 PM Friday is not considered
  overdue by Saturday morning.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias MyApp.Support.{Ticket, SLABreach}

  @business_hours_start 9
  @business_hours_end 17
  @business_days ~w(monday tuesday wednesday thursday friday)a

  @priority_response_hours %{
    urgent: 1,
    high: 4,
    normal: 24,
    low: 72
  }

  @tier_multipliers %{
    enterprise: 0.5,
    pro: 0.75,
    free: 1.0
  }

  @type priority :: :urgent | :high | :normal | :low
  @type tier :: :enterprise | :pro | :free

  @doc """
  Computes the response deadline for a ticket opened at `opened_at` with
  the given `priority` and customer `tier`. Business hours only.
  """
  @spec deadline(DateTime.t(), priority(), tier()) :: DateTime.t()
  def deadline(opened_at, priority, tier) do
    base_hours = Map.fetch!(@priority_response_hours, priority)
    multiplier = Map.get(@tier_multipliers, tier, 1.0)
    target_hours = base_hours * multiplier
    add_business_hours(opened_at, target_hours)
  end

  @doc "Returns `true` when `ticket` has breached its response SLA."
  @spec breached?(Ticket.t()) :: boolean()
  def breached?(%Ticket{} = ticket) do
    dl = deadline(ticket.inserted_at, ticket.priority, ticket.customer_tier)
    is_nil(ticket.first_response_at) and DateTime.compare(DateTime.utc_now(), dl) == :gt
  end

  @doc """
  Scans all open tickets without a first response and records SLA
  breaches for those past their deadline. Returns the count of new
  breaches recorded.
  """
  @spec record_breaches() :: non_neg_integer()
  def record_breaches do
    open_without_response = fetch_open_without_response()
    now = DateTime.utc_now()

    new_breaches =
      open_without_response
      |> Enum.filter(fn ticket ->
        dl = deadline(ticket.inserted_at, ticket.priority, ticket.customer_tier)
        DateTime.compare(now, dl) == :gt
      end)
      |> Enum.reject(&already_breached?/1)

    Enum.each(new_breaches, &insert_breach/1)
    length(new_breaches)
  end

  @spec add_business_hours(DateTime.t(), float()) :: DateTime.t()
  defp add_business_hours(start_dt, hours) do
    minutes = round(hours * 60)
    advance_business_minutes(start_dt, minutes)
  end

  @spec advance_business_minutes(DateTime.t(), non_neg_integer()) :: DateTime.t()
  defp advance_business_minutes(dt, 0), do: dt

  defp advance_business_minutes(dt, minutes_remaining) do
    if in_business_hours?(dt) do
      end_of_business = %{dt | hour: @business_hours_end, minute: 0, second: 0}
      minutes_until_eob = max(DateTime.diff(end_of_business, dt, :minute), 0)

      if minutes_remaining <= minutes_until_eob do
        DateTime.add(dt, minutes_remaining * 60, :second)
      else
        next_start = next_business_start(dt)
        advance_business_minutes(next_start, minutes_remaining - minutes_until_eob)
      end
    else
      advance_business_minutes(next_business_start(dt), minutes_remaining)
    end
  end

  @spec in_business_hours?(DateTime.t()) :: boolean()
  defp in_business_hours?(dt) do
    day = dt |> DateTime.to_date() |> Date.day_of_week() |> day_atom()
    day in @business_days and dt.hour >= @business_hours_start and dt.hour < @business_hours_end
  end

  @spec next_business_start(DateTime.t()) :: DateTime.t()
  defp next_business_start(dt) do
    next_day = DateTime.add(dt, 86_400, :second)
    start = %{next_day | hour: @business_hours_start, minute: 0, second: 0}

    if in_business_hours?(start), do: start, else: next_business_start(start)
  end

  @spec day_atom(pos_integer()) :: atom()
  defp day_atom(1), do: :monday
  defp day_atom(2), do: :tuesday
  defp day_atom(3), do: :wednesday
  defp day_atom(4), do: :thursday
  defp day_atom(5), do: :friday
  defp day_atom(6), do: :saturday
  defp day_atom(7), do: :sunday

  @spec fetch_open_without_response() :: [Ticket.t()]
  defp fetch_open_without_response do
    Ticket
    |> where([t], t.status in [:open, :pending] and is_nil(t.first_response_at))
    |> Repo.all()
  end

  @spec already_breached?(Ticket.t()) :: boolean()
  defp already_breached?(ticket) do
    SLABreach
    |> where([b], b.ticket_id == ^ticket.id)
    |> Repo.exists?()
  end

  @spec insert_breach(Ticket.t()) :: :ok
  defp insert_breach(ticket) do
    %SLABreach{}
    |> SLABreach.changeset(%{
      ticket_id: ticket.id,
      breach_type: :first_response,
      deadline: deadline(ticket.inserted_at, ticket.priority, ticket.customer_tier),
      breached_at: DateTime.utc_now()
    })
    |> Repo.insert()

    :ok
  end
end
```
