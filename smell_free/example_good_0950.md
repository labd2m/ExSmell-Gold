```elixir
defmodule Commerce.ReturnContext do
  @moduledoc """
  Manages the customer return merchandise authorisation (RMA) process.
  A return request is initiated against specific line items of a delivered
  order. The context validates eligibility, records the authorisation,
  and triggers the refund pipeline once the return is confirmed received.
  Return windows and reasons are configurable per product category.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Commerce.{Order, ReturnRequest, ReturnLineItem}
  alias Payments.RefundContext

  @type order_id :: String.t()
  @type return_id :: Ecto.UUID.t()
  @type return_reason :: :defective | :wrong_item | :not_as_described | :changed_mind

  @default_return_window_days 30

  @doc """
  Initiates a return request for selected line items of `order_id`.
  Returns `{:error, :outside_return_window}` when the order is older
  than the return window.
  """
  @spec initiate(order_id(), [%{line_item_id: String.t(), reason: return_reason()}]) ::
          {:ok, ReturnRequest.t()}
          | {:error, :order_not_found | :outside_return_window | Ecto.Changeset.t()}
  def initiate(order_id, line_item_requests)
      when is_binary(order_id) and is_list(line_item_requests) do
    with {:ok, order} <- fetch_delivered_order(order_id),
         :ok <- check_return_window(order) do
      Repo.transaction(fn ->
        attrs = %{order_id: order_id, status: "pending", customer_id: order.customer_id}

        with {:ok, request} <- %ReturnRequest{} |> ReturnRequest.changeset(attrs) |> Repo.insert(),
             :ok <- insert_return_line_items(request.id, line_item_requests, order) do
          Repo.preload(request, :return_line_items)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc "Marks a return as received and triggers the refund pipeline."
  @spec confirm_received(return_id()) ::
          {:ok, ReturnRequest.t()} | {:error, :not_found | :not_pending}
  def confirm_received(return_id) when is_binary(return_id) do
    case Repo.get(ReturnRequest, return_id) |> Repo.preload(:return_line_items) do
      nil ->
        {:error, :not_found}

      %ReturnRequest{status: "pending"} = request ->
        Repo.transaction(fn ->
          updated = request |> ReturnRequest.status_changeset("received") |> Repo.update!()
          process_refund(request)
          updated
        end)

      %ReturnRequest{} ->
        {:error, :not_pending}
    end
  end

  @doc "Returns all return requests for `order_id` in reverse-chronological order."
  @spec list_for_order(order_id()) :: [ReturnRequest.t()]
  def list_for_order(order_id) when is_binary(order_id) do
    from(r in ReturnRequest,
      where: r.order_id == ^order_id,
      order_by: [desc: r.inserted_at],
      preload: [:return_line_items]
    )
    |> Repo.all()
  end

  defp fetch_delivered_order(order_id) do
    case Repo.get(Order, order_id) do
      nil -> {:error, :order_not_found}
      %Order{status: "delivered"} = order -> {:ok, order}
      %Order{} -> {:error, :order_not_found}
    end
  end

  defp check_return_window(%Order{fulfilled_at: nil}), do: {:error, :outside_return_window}

  defp check_return_window(%Order{fulfilled_at: fulfilled_at}) do
    cutoff = DateTime.add(fulfilled_at, @default_return_window_days * 86_400, :second)
    if DateTime.compare(DateTime.utc_now(), cutoff) == :gt do
      {:error, :outside_return_window}
    else
      :ok
    end
  end

  defp insert_return_line_items(return_id, requests, order) do
    Enum.reduce_while(requests, :ok, fn req, _acc ->
      line_item = Enum.find(order.line_items, fn li -> li.id == req.line_item_id end)
      attrs = %{return_request_id: return_id, line_item_id: req.line_item_id,
                reason: Atom.to_string(req.reason),
                amount_cents: if(line_item, do: line_item.unit_price_cents, else: 0)}

      case %ReturnLineItem{} |> ReturnLineItem.changeset(attrs) |> Repo.insert() do
        {:ok, _} -> {:cont, :ok}
        {:error, cs} -> {:halt, {:error, cs}}
      end
    end)
  end

  defp process_refund(%ReturnRequest{id: return_id} = request) do
    total = Enum.sum_by(request.return_line_items, & &1.amount_cents)
    order = Repo.get!(Order, request.order_id)
    RefundContext.issue(order.charge_id, total, "return_#{return_id}")
  end
end
```
