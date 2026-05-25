# Annotated Example — Large Module

- **Smell name:** Large Class (Large Module)
- **Expected smell location:** The entire `DeliveryCoordinator` module
- **Affected functions:** `assign_driver/2`, `update_delivery_status/2`, `calculate_route/2`, `estimate_arrival/2`, `handle_failed_delivery/2`, `reschedule_delivery/2`, `notify_customer_eta/2`, `collect_signature/2`, `generate_delivery_report/2`, `rate_driver/2`
- **Short explanation:** `DeliveryCoordinator` combines driver assignment, status tracking, route calculation, ETA estimation, failure handling and rescheduling, customer ETA notifications, proof-of-delivery (signature), reporting, and driver rating. These responsibilities span fleet management, routing, communication, compliance, analytics, and feedback — each a separate concern that should have its own module.

```elixir
# VALIDATION: SMELL START - Large Class (Large Module)
# VALIDATION: This is a smell because DeliveryCoordinator handles driver
# assignment, delivery status tracking, route and ETA calculation, failed
# delivery workflows, customer ETA notifications, proof-of-delivery capture,
# analytics reporting, and driver rating — eight separate concerns spanning
# fleet management, routing, communication, and analytics in one module.
defmodule DeliveryCoordinator do
  @moduledoc """
  End-to-end last-mile delivery management: driver assignment, route
  calculation, status tracking, ETA estimation, failure handling,
  rescheduling, customer notifications, proof-of-delivery, reporting,
  and driver rating.
  """

  require Logger
  import Ecto.Query
  alias Delivery.Repo
  alias Delivery.DeliveryTask
  alias Delivery.Driver
  alias Delivery.RouteSegment
  alias Delivery.DeliveryAttempt
  alias Delivery.DriverRating

  @max_reschedule_attempts 3
  @avg_speed_kmh 35.0

  # --- Driver assignment ---

  def assign_driver(%DeliveryTask{} = task, opts \\ []) do
    preferred_driver_id = Keyword.get(opts, :driver_id)

    driver =
      if preferred_driver_id do
        Repo.get!(Driver, preferred_driver_id)
      else
        find_available_driver(task.pickup_zone)
      end

    case driver do
      nil ->
        {:error, :no_driver_available}

      driver ->
        task
        |> DeliveryTask.changeset(%{
             driver_id: driver.id,
             status: :assigned,
             assigned_at: DateTime.utc_now()
           })
        |> Repo.update()
    end
  end

  defp find_available_driver(zone) do
    from(d in Driver,
      where: d.status == :available and d.current_zone == ^zone,
      order_by: [asc: d.active_deliveries],
      limit: 1
    )
    |> Repo.one()
  end

  # --- Status updates ---

  def update_delivery_status(%DeliveryTask{} = task, new_status) do
    valid_transitions = %{
      assigned: [:picked_up, :cancelled],
      picked_up: [:in_transit, :failed],
      in_transit: [:delivered, :failed],
      failed: [:rescheduled]
    }

    allowed = Map.get(valid_transitions, task.status, [])

    if new_status in allowed do
      task
      |> DeliveryTask.changeset(%{status: new_status, updated_at: DateTime.utc_now()})
      |> Repo.update()
    else
      {:error, {:invalid_transition, task.status, new_status}}
    end
  end

  # --- Route calculation ---

  def calculate_route(%DeliveryTask{} = task) do
    origin = task.pickup_coordinates
    dest   = task.delivery_coordinates

    case RoutingAPI.get_route(%{origin: origin, destination: dest, mode: :driving}) do
      {:ok, %{distance_km: dist, waypoints: wps}} ->
        Enum.each(wps, fn {lat, lng, seq} ->
          Repo.insert!(
            RouteSegment.changeset(%RouteSegment{}, %{
              task_id: task.id,
              latitude: lat,
              longitude: lng,
              sequence: seq
            })
          )
        end)

        task
        |> DeliveryTask.changeset(%{route_distance_km: dist})
        |> Repo.update!()

        {:ok, dist}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- ETA estimation ---

  def estimate_arrival(%DeliveryTask{} = task, current_location) do
    lat_diff = task.delivery_coordinates.lat - current_location.lat
    lng_diff = task.delivery_coordinates.lng - current_location.lng
    dist_km  = :math.sqrt(lat_diff * lat_diff + lng_diff * lng_diff) * 111.0
    hours    = dist_km / @avg_speed_kmh
    eta      = DateTime.add(DateTime.utc_now(), round(hours * 3600), :second)
    {:ok, eta}
  end

  # --- Failed delivery handling ---

  def handle_failed_delivery(%DeliveryTask{} = task, reason) do
    attempts = count_attempts(task.id)

    Repo.insert!(
      DeliveryAttempt.changeset(%DeliveryAttempt{}, %{
        task_id: task.id,
        attempt_number: attempts + 1,
        failure_reason: reason,
        attempted_at: DateTime.utc_now()
      })
    )

    if attempts + 1 >= @max_reschedule_attempts do
      task |> DeliveryTask.changeset(%{status: :failed_permanently}) |> Repo.update!()
      {:error, :max_attempts_reached}
    else
      {:ok, :failure_recorded}
    end
  end

  defp count_attempts(task_id) do
    from(a in DeliveryAttempt, where: a.task_id == ^task_id) |> Repo.aggregate(:count, :id)
  end

  # --- Rescheduling ---

  def reschedule_delivery(%DeliveryTask{} = task, new_slot) do
    task
    |> DeliveryTask.changeset(%{
         status: :rescheduled,
         scheduled_at: new_slot,
         driver_id: nil
       })
    |> Repo.update()
  end

  # --- Customer ETA notification ---

  def notify_customer_eta(%DeliveryTask{} = task, eta) do
    order = Repo.get!(Delivery.Order, task.order_id)
    customer = Repo.get!(Delivery.User, order.user_id)

    eta_str = Calendar.strftime(eta, "%H:%M on %d %b")

    Mailer.deliver(%{
      to: customer.email,
      subject: "Your delivery is on the way",
      text_body: "Your order will arrive approximately #{eta_str}. Please ensure someone is available."
    })

    :ok
  end

  # --- Proof of delivery (signature) ---

  def collect_signature(%DeliveryTask{} = task, signature_data) do
    with {:ok, updated} <-
           task
           |> DeliveryTask.changeset(%{
                signature_data: signature_data,
                signature_collected_at: DateTime.utc_now(),
                status: :delivered
              })
           |> Repo.update() do
      Logger.info("Signature collected for delivery task #{task.id}")
      {:ok, updated}
    end
  end

  # --- Delivery reporting ---

  def generate_delivery_report(driver_id, date_range) do
    tasks =
      from(dt in DeliveryTask,
        where:
          dt.driver_id == ^driver_id and
            dt.updated_at >= ^date_range.from and
            dt.updated_at <= ^date_range.to
      )
      |> Repo.all()

    total     = length(tasks)
    delivered = Enum.count(tasks, &(&1.status == :delivered))
    failed    = Enum.count(tasks, &(&1.status == :failed_permanently))
    avg_dist  = if total > 0, do: Enum.sum(Enum.map(tasks, &(&1.route_distance_km || 0))) / total, else: 0.0

    %{
      driver_id: driver_id,
      period: date_range,
      total: total,
      delivered: delivered,
      failed: failed,
      success_rate: if(total > 0, do: Float.round(delivered / total * 100, 1), else: 0.0),
      avg_distance_km: Float.round(avg_dist, 1)
    }
  end

  # --- Driver rating ---

  def rate_driver(%DeliveryTask{} = task, %{score: score, comment: comment})
      when score in 1..5 do
    attrs = %{
      driver_id: task.driver_id,
      task_id: task.id,
      score: score,
      comment: comment,
      rated_at: DateTime.utc_now()
    }

    case Repo.insert(DriverRating.changeset(%DriverRating{}, attrs)) do
      {:ok, rating} ->
        Logger.info("Driver #{task.driver_id} rated #{score}/5 for task #{task.id}")
        {:ok, rating}

      {:error, cs} ->
        {:error, cs}
    end
  end

  def rate_driver(_, _), do: {:error, :invalid_score}
end
# VALIDATION: SMELL END
```
