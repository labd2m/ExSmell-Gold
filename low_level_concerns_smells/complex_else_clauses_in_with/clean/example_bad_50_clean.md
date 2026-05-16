```elixir
defmodule Returns.RMAService do
  @moduledoc """
  Manages Return Merchandise Authorizations (RMAs):
  order verification, eligibility assessment, return reason validation,
  RMA record creation, and prepaid label dispatch.
  """

  alias Returns.{
    OrderRepo,
    EligibilityChecker,
    ReasonRegistry,
    RMARepo,
    LabelMailer
  }

  require Logger

  @doc """
  Creates an RMA for `order_id` on behalf of `customer_id`.

  `params` must include `:reason_code`, `:line_item_ids`, and `:comments`.

  Returns `{:ok, rma}` or a structured error.
  """
  @spec create_rma(String.t(), map()) ::
          {:ok, map()}
          | {:error, :order_not_found}
          | {:error, :not_eligible, String.t()}
          | {:error, :invalid_reason_code}
          | {:error, :rma_creation_failed}
          | {:error, :label_dispatch_failed}
  def create_rma(customer_id, %{order_id: order_id} = params) do
    with {:ok, order}  <- OrderRepo.fetch_for_customer(order_id, customer_id),
         :ok           <- EligibilityChecker.check(order, params.line_item_ids),
         {:ok, reason} <- ReasonRegistry.fetch(params.reason_code),
         {:ok, rma}    <- RMARepo.insert(%{
                            order_id:      order.id,
                            customer_id:   customer_id,
                            reason_id:     reason.id,
                            line_item_ids: params.line_item_ids,
                            comments:      params.comments,
                            status:        :pending,
                            created_at:    DateTime.utc_now()
                          }),
         :ok           <- LabelMailer.send_prepaid_label(order.customer_email, rma) do
      Logger.info("RMA #{rma.id} created for order #{order_id}, customer #{customer_id}")
      {:ok, rma}
    else
      {:error, :not_found} ->
        Logger.warn("Order #{order_id} not found for customer #{customer_id}")
        {:error, :order_not_found}

      {:ineligible, reason_msg} ->
        Logger.info("Order #{order_id} not eligible for return: #{reason_msg}")
        {:error, :not_eligible, reason_msg}

      :invalid_reason ->
        Logger.warn("Reason code #{params.reason_code} not found in registry")
        {:error, :invalid_reason_code}

      {:error, %Ecto.Changeset{} = cs} ->
        Logger.error("RMA insert failed: #{inspect(cs.errors)}")
        {:error, :rma_creation_failed}

      {:error, :label, detail} ->
        Logger.error("Prepaid label dispatch failed: #{inspect(detail)}")
        {:error, :label_dispatch_failed}
    end
  end
end
```
