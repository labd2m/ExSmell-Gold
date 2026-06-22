```elixir
defmodule Orders.FulfillmentStateMachine do
  @moduledoc """
  Enforces valid state transitions for order fulfillment lifecycle.
  Each transition is an explicit function that validates preconditions,
  applies side effects, and persists the resulting status atomically.
  """

  alias Orders.{Repo, Order, Warehouse, Carrier, CustomerMailer}
  alias Ecto.Multi

  @type transition_result :: {:ok, Order.t()} | {:error, atom() | Ecto.Changeset.t()}

  @spec confirm(Order.t()) :: transition_result()
  def confirm(%Order{status: :pending} = order) do
    multi =
      Multi.new()
      |> Multi.update(:order, Order.status_changeset(order, :confirmed))
      |> Multi.run(:notify, fn _repo, %{order: updated} ->
        CustomerMailer.send_confirmation(updated)
      end)

    run_transition(multi)
  end

  def confirm(%Order{}), do: {:error, :invalid_transition}

  @spec allocate(Order.t()) :: transition_result()
  def allocate(%Order{status: :confirmed} = order) do
    multi =
      Multi.new()
      |> Multi.run(:allocation, fn _repo, _ -> Warehouse.allocate_stock(order) end)
      |> Multi.update(:order, Order.status_changeset(order, :allocated))

    run_transition(multi)
  end

  def allocate(%Order{}), do: {:error, :invalid_transition}

  @spec ship(Order.t(), map()) :: transition_result()
  def ship(%Order{status: :allocated} = order, shipment_params) when is_map(shipment_params) do
    multi =
      Multi.new()
      |> Multi.run(:label, fn _repo, _ -> Carrier.create_label(order, shipment_params) end)
      |> Multi.update(:order, fn %{label: label} ->
        Order.shipment_changeset(order, %{
          status: :shipped,
          tracking_number: label.tracking_number,
          carrier: label.carrier,
          shipped_at: DateTime.utc_now()
        })
      end)
      |> Multi.run(:notify, fn _repo, %{order: updated} ->
        CustomerMailer.send_shipment_notification(updated)
      end)

    run_transition(multi)
  end

  def ship(%Order{}, _), do: {:error, :invalid_transition}

  @spec deliver(Order.t()) :: transition_result()
  def deliver(%Order{status: :shipped} = order) do
    multi =
      Multi.new()
      |> Multi.update(:order, Order.status_changeset(order, :delivered, %{delivered_at: DateTime.utc_now()}))
      |> Multi.run(:notify, fn _repo, %{order: updated} ->
        CustomerMailer.send_delivery_confirmation(updated)
      end)

    run_transition(multi)
  end

  def deliver(%Order{}), do: {:error, :invalid_transition}

  @spec cancel(Order.t(), atom()) :: transition_result()
  def cancel(%Order{status: status} = order, reason)
      when status in [:pending, :confirmed] and is_atom(reason) do
    multi =
      Multi.new()
      |> Multi.update(:order, Order.cancellation_changeset(order, reason))
      |> Multi.run(:notify, fn _repo, %{order: updated} ->
        CustomerMailer.send_cancellation(updated)
      end)

    run_transition(multi)
  end

  def cancel(%Order{}, _), do: {:error, :invalid_transition}

  @spec run_transition(Ecto.Multi.t()) :: transition_result()
  defp run_transition(multi) do
    case Repo.transaction(multi) do
      {:ok, %{order: order}} -> {:ok, order}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end
end
```
