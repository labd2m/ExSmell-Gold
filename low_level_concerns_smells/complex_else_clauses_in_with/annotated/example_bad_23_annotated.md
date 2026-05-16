# Annotated Bad Example 23

- **Smell name:** Complex else clauses in with
- **Expected smell location:** `purchase_tickets/3`, inside the `with` block's `else` clause
- **Affected function(s):** `purchase_tickets/3`
- **Short explanation:** A ticket purchase pipeline with six steps—loading the event, checking seat availability, reserving seats, charging the buyer, issuing ticket records, and sending a confirmation email—each fail differently, yet all errors are handled in a single `else` block with no attribution to the step that caused them.

```elixir
defmodule Ticketing.PurchaseService do
  alias Ticketing.{
    Repo,
    Event,
    SeatMap,
    SeatReservation,
    PaymentGateway,
    Ticket,
    ConfirmationMailer
  }

  require Logger

  @reservation_hold_minutes 15

  def purchase_tickets(event_id, buyer_id, order_params) do
    seat_ids = Map.fetch!(order_params, :seat_ids)
    payment_token = Map.fetch!(order_params, :payment_token)

    with {:ok, event} <- fetch_on_sale_event(event_id),
         {:ok, seats} <- SeatMap.check_availability(event_id, seat_ids),
         {:ok, hold} <- SeatReservation.hold(seats, buyer_id, @reservation_hold_minutes),
         {:ok, charge} <- PaymentGateway.charge(payment_token, hold.total_price_cents),
         {:ok, tickets} <- issue_tickets(event, seats, buyer_id, charge),
         :ok <- ConfirmationMailer.send(buyer_id, event, tickets) do
      SeatReservation.confirm(hold)

      Logger.info(
        "Ticket purchase complete: buyer=#{buyer_id} event=#{event_id} " <>
          "seats=#{length(seats)} charge=#{charge.id}"
      )

      {:ok, %{tickets: tickets, charge_id: charge.id}}
    else
      # VALIDATION: SMELL START - Complex else clauses in with
      # VALIDATION: This is a smell because six pipeline steps each produce distinct errors
      # that are all collected in one `else` block. `:event_not_found`, `:sales_not_open`,
      # and `:event_cancelled` come from event fetching; `:seats_unavailable` and
      # `:seat_ids_invalid` from availability checking; `:hold_failed` from reservation
      # holding; `:payment_declined`, `:card_expired`, and `:gateway_error` from charging;
      # `:ticket_issuance_failed` from ticket creation; and `:confirmation_email_failed`
      # from mailing — all with no structural separation.
      {:error, :event_not_found} ->
        Logger.warning("Event #{event_id} not found during ticket purchase")
        {:error, :event_not_found}

      {:error, :sales_not_open} ->
        Logger.warning("Ticket sales are not open for event #{event_id}")
        {:error, :sales_not_open}

      {:error, :event_cancelled} ->
        Logger.warning("Purchase attempted on cancelled event #{event_id}")
        {:error, :event_cancelled}

      {:error, :seats_unavailable} ->
        Logger.info("Requested seats unavailable for event #{event_id}")
        {:error, :seats_unavailable}

      {:error, :seat_ids_invalid} ->
        Logger.warning("One or more seat IDs are invalid for event #{event_id}")
        {:error, :invalid_seat_selection}

      {:error, :hold_failed} ->
        Logger.warning("Could not hold seats for buyer #{buyer_id} on event #{event_id}")
        {:error, :seat_hold_failed}

      {:error, :payment_declined} ->
        Logger.info("Payment declined for buyer #{buyer_id} on event #{event_id}")
        {:error, :payment_declined}

      {:error, :card_expired} ->
        Logger.info("Expired card used by buyer #{buyer_id}")
        {:error, :payment_method_invalid}

      {:error, :gateway_error} ->
        Logger.error("Payment gateway error during ticket purchase for event #{event_id}")
        {:error, :payment_gateway_error}

      {:error, :ticket_issuance_failed} ->
        Logger.error("Ticket issuance failed for buyer #{buyer_id} — charge may need reversal")
        {:error, :issuance_failed}

      {:error, :confirmation_email_failed} ->
        Logger.warning("Confirmation email failed for buyer #{buyer_id} — tickets still issued")
        {:error, :email_delivery_failed}
      # VALIDATION: SMELL END
    end
  end

  defp fetch_on_sale_event(event_id) do
    case Repo.get(Event, event_id) do
      nil -> {:error, :event_not_found}
      %Event{status: :cancelled} -> {:error, :event_cancelled}
      %Event{sales_open: false} -> {:error, :sales_not_open}
      event -> {:ok, event}
    end
  end

  defp issue_tickets(event, seats, buyer_id, charge) do
    tickets =
      Enum.map(seats, fn seat ->
        %Ticket{
          event_id: event.id,
          seat_id: seat.id,
          buyer_id: buyer_id,
          charge_id: charge.id,
          issued_at: DateTime.utc_now(),
          status: :active
        }
      end)

    case Repo.insert_all(Ticket, tickets, returning: true) do
      {count, records} when count == length(seats) -> {:ok, records}
      _ -> {:error, :ticket_issuance_failed}
    end
  end
end
```
