# Code Smell: "Use" instead of "import"

## Metadata

- **Smell name:** "Use" instead of "import"
- **Expected smell location:** `ShipmentTracker` module, top-level directive
- **Affected function(s):** `record_event/2`, `current_status/1`, `estimated_delivery/1`
- **Short explanation:** `ShipmentTracker` calls `use TrackingHelpers` to obtain status-transition and date-formatting utilities. The `__using__/1` macro injects an `import` of `DateUtils` into the caller, propagating a hidden dependency. Replacing `use TrackingHelpers` with `import TrackingHelpers` (and explicitly importing `DateUtils` where needed) would make every dependency visible at a glance.

---

```elixir
defmodule DateUtils do
  def format_iso(datetime), do: DateTime.to_iso8601(datetime)

  def business_days_from_now(n) do
    Stream.iterate(DateTime.utc_now(), &DateTime.add(&1, 86_400, :second))
    |> Stream.reject(&(Date.day_of_week(DateTime.to_date(&1)) in [6, 7]))
    |> Enum.at(n)
  end

  def humanize_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)} min"
  def humanize_duration(seconds) when seconds < 86_400, do: "#{div(seconds, 3600)} h"
  def humanize_duration(seconds), do: "#{div(seconds, 86_400)} d"
end

defmodule TrackingHelpers do
  defmacro __using__(_opts) do
    quote do
      # VALIDATION: SMELL START - "Use" instead of "import"
      # VALIDATION: This is a smell because the __using__/1 macro silently imports DateUtils
      # VALIDATION: into ShipmentTracker. ShipmentTracker's author has no indication that
      # VALIDATION: format_iso/1, business_days_from_now/1, and humanize_duration/1 come
      # VALIDATION: from DateUtils rather than from TrackingHelpers itself.
      # VALIDATION: A simple `import TrackingHelpers` at the call site would be transparent.
      import DateUtils
      # VALIDATION: SMELL END

      @valid_transitions %{
        created:     [:picked_up],
        picked_up:   [:in_transit, :failed],
        in_transit:  [:out_for_delivery, :delayed, :failed],
        delayed:     [:in_transit, :failed],
        out_for_delivery: [:delivered, :failed],
        delivered:   [],
        failed:      [:created]
      }

      def valid_transition?(from, to) do
        to in Map.get(@valid_transitions, from, [])
      end

      def transition_label(from, to) do
        if valid_transition?(from, to) do
          {:ok, "#{from} → #{to}"}
        else
          {:error, "Invalid transition: #{from} → #{to}"}
        end
      end
    end
  end
end

defmodule ShipmentTracker do
  use TrackingHelpers

  @carrier_lead_days %{
    "fedex"  => 2,
    "ups"    => 3,
    "usps"   => 5,
    "dhl"    => 4
  }

  def record_event(shipment, event) do
    case valid_transition?(shipment.status, event.type) do
      true ->
        updated = %{
          shipment |
          status:      event.type,
          last_update: format_iso(event.occurred_at),
          history:     shipment.history ++ [event]
        }
        {:ok, updated}

      false ->
        {:error, "Cannot transition from #{shipment.status} to #{event.type}"}
    end
  end

  def current_status(shipment) do
    elapsed = DateTime.diff(DateTime.utc_now(), shipment.created_at)
    %{
      id:           shipment.id,
      status:       shipment.status,
      last_updated: format_iso(shipment.last_update),
      age:          humanize_duration(elapsed)
    }
  end

  def estimated_delivery(shipment) do
    lead = Map.get(@carrier_lead_days, shipment.carrier, 5)

    case shipment.status do
      :delivered -> {:ok, format_iso(shipment.delivered_at)}
      :failed    -> {:error, "Shipment failed; no delivery estimate available"}
      _          ->
        eta = business_days_from_now(lead)
        {:ok, format_iso(eta)}
    end
  end

  def build_manifest(shipments) do
    Enum.map(shipments, fn s ->
      {:ok, status} = {:ok, current_status(s)}
      {label, _}    = transition_label(s.status, :delivered)
      Map.put(status, :next_step, label)
    end)
  end

  def overdue?(shipment) do
    lead  = Map.get(@carrier_lead_days, shipment.carrier, 5)
    limit = business_days_from_now(-lead)
    DateTime.compare(shipment.created_at, limit) == :lt and
      shipment.status not in [:delivered, :failed]
  end
end
```
