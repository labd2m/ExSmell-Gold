```elixir
defmodule ReturnProcessor do
  @moduledoc """
  Manages the merchandise return lifecycle for the e-commerce logistics platform.
  Determines restocking eligibility, carrier liability, and available resolution
  paths based on the stated reason for the return request.
  """

  require Logger

  @return_reasons [
    :damaged_in_transit,
    :wrong_item_sent,
    :customer_changed_mind,
    :defective_product
  ]

  def valid_return_reasons, do: @return_reasons







  @doc """
  Returns true when an item returned for the given reason can be restocked
  and resold after inspection.
  """
  def restocking_eligible?(%{reason: reason}) do
    case reason do
      :damaged_in_transit -> false
      :wrong_item_sent -> true
      :customer_changed_mind -> true
      :defective_product -> false
      _ -> false
    end
  end

  @doc """
  Returns true when the carrier bears financial responsibility for the return,
  meaning a claim should be opened against them rather than the merchant absorbing
  the cost.
  """
  def carrier_responsible?(%{reason: reason}) do
    case reason do
      :damaged_in_transit -> true
      :wrong_item_sent -> false
      :customer_changed_mind -> false
      :defective_product -> false
      _ -> false
    end
  end

  @doc """
  Returns the set of resolution options available to the customer for the given
  return reason. Options may include refund, replacement, or store credit.
  """
  def resolution_options(%{reason: reason}) do
    case reason do
      :damaged_in_transit -> [:full_refund, :replacement]
      :wrong_item_sent -> [:full_refund, :replacement, :store_credit]
      :customer_changed_mind -> [:store_credit, :partial_refund]
      :defective_product -> [:full_refund, :replacement, :store_credit]
      _ -> [:store_credit]
    end
  end



  @doc """
  Validates that the return request struct is well-formed.
  """
  def validate_request(
        %{order_id: _, item_id: _, reason: reason, requested_resolution: _} = request
      )
      when reason in @return_reasons do
    {:ok, request}
  end

  def validate_request(%{reason: reason}) when reason not in @return_reasons do
    {:error, {:unknown_reason, reason}}
  end

  def validate_request(_), do: {:error, :invalid_return_request}

  @doc """
  Checks whether the customer's requested resolution is one of those permitted
  for the return reason.
  """
  def resolution_permitted?(%{reason: _} = return_request, requested_resolution) do
    options = resolution_options(return_request)
    requested_resolution in options
  end

  @doc """
  Initiates the return workflow, routing the request to the correct handling path.
  Returns a return authorisation record.
  """
  def initiate(%{} = return_request) do
    with {:ok, valid} <- validate_request(return_request) do
      can_restock = restocking_eligible?(valid)
      carrier_claim = carrier_responsible?(valid)
      options = resolution_options(valid)

      unless resolution_permitted?(valid, valid.requested_resolution) do
        Logger.warning(
          "Resolution #{valid.requested_resolution} not permitted for reason #{valid.reason}."
        )
      end

      rma = %{
        rma_number: generate_rma_number(),
        order_id: valid.order_id,
        item_id: valid.item_id,
        reason: valid.reason,
        requested_resolution: valid.requested_resolution,
        permitted_resolutions: options,
        restock_on_receipt: can_restock,
        open_carrier_claim: carrier_claim,
        status: :pending_return,
        created_at: DateTime.utc_now()
      }

      Logger.info("RMA #{rma.rma_number} created for order #{valid.order_id}.")
      {:ok, rma}
    end
  end

  @doc """
  Processes a received return shipment, updating the RMA and triggering the
  appropriate downstream actions (restocking, carrier claims, refund).
  """
  def receive_return(%{status: :pending_return} = rma, condition) do
    final_restock = rma.restock_on_receipt and condition == :acceptable

    actions =
      []
      |> then(fn acc -> if final_restock, do: [:restock | acc], else: acc end)
      |> then(fn acc -> if rma.open_carrier_claim, do: [:file_carrier_claim | acc], else: acc end)
      |> then(fn acc -> [:process_resolution | acc] end)

    updated = %{rma | status: :received, received_at: DateTime.utc_now(), actions_taken: actions}

    Logger.info("Return #{rma.rma_number} received in #{condition} condition. Actions: #{inspect(actions)}.")
    {:ok, updated}
  end

  def receive_return(%{status: status}, _condition) do
    {:error, {:invalid_rma_status, status}}
  end



  defp generate_rma_number do
    "RMA-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16())
  end
end
```
