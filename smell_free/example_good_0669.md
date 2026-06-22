```elixir
defmodule MyApp.Ecommerce.ReturnProcessor do
  @moduledoc """
  Processes customer return requests through a validated state machine.
  A return transitions from `:requested` through `:approved` or
  `:rejected`, then `:received` and `:refunded`. Each transition
  validates that the requested status change is permitted and fires the
  appropriate downstream action — notifying the customer, issuing a
  refund credit, or restocking inventory.
  """

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.Ecommerce.{Return, Order}
  alias MyApp.Billing.Payments
  alias MyApp.Notifications.Dispatcher
  alias MyApp.Inventory.StockLevel

  @allowed_transitions %{
    requested: [:approved, :rejected],
    approved: [:received, :cancelled],
    received: [:refunded],
    rejected: [],
    refunded: [],
    cancelled: []
  }

  @type return_id :: String.t()
  @type actor_id :: String.t()
  @type status :: :requested | :approved | :rejected | :received | :refunded | :cancelled

  @doc """
  Transitions `return` to `new_status` as `actor_id`. Executes any
  required downstream actions atomically with the status update.
  """
  @spec transition(Return.t(), status(), actor_id()) ::
          {:ok, Return.t()} | {:error, :invalid_transition} | {:error, atom(), term(), map()}
  def transition(%Return{} = return, new_status, actor_id) do
    if transition_allowed?(return.status, new_status) do
      execute_transition(return, new_status, actor_id)
    else
      {:error, :invalid_transition}
    end
  end

  @doc "Returns `true` when `from` → `to` is a permitted transition."
  @spec transition_allowed?(status(), status()) :: boolean()
  def transition_allowed?(from, to) do
    to in Map.get(@allowed_transitions, from, [])
  end

  @spec execute_transition(Return.t(), status(), actor_id()) ::
          {:ok, Return.t()} | {:error, atom(), term(), map()}
  defp execute_transition(return, :approved, actor_id) do
    Multi.new()
    |> Multi.run(:return, fn _repo, _ ->
      return |> Return.transition_changeset(:approved, actor_id) |> Repo.update()
    end)
    |> Multi.run(:notify, fn _repo, %{return: updated} ->
      notify_customer(updated, :return_approved)
    end)
    |> Repo.transaction()
    |> unwrap_result()
  end

  defp execute_transition(return, :rejected, actor_id) do
    Multi.new()
    |> Multi.run(:return, fn _repo, _ ->
      return |> Return.transition_changeset(:rejected, actor_id) |> Repo.update()
    end)
    |> Multi.run(:notify, fn _repo, %{return: updated} ->
      notify_customer(updated, :return_rejected)
    end)
    |> Repo.transaction()
    |> unwrap_result()
  end

  defp execute_transition(return, :refunded, actor_id) do
    Multi.new()
    |> Multi.run(:return, fn _repo, _ ->
      return |> Return.transition_changeset(:refunded, actor_id) |> Repo.update()
    end)
    |> Multi.run(:refund, fn _repo, %{return: updated} ->
      Payments.issue_refund(updated.order_id, updated.refund_amount_cents)
    end)
    |> Multi.run(:restock, fn _repo, %{return: updated} ->
      restock_items(updated)
    end)
    |> Multi.run(:notify, fn _repo, %{return: updated} ->
      notify_customer(updated, :return_refunded)
    end)
    |> Repo.transaction()
    |> unwrap_result()
  end

  defp execute_transition(return, new_status, actor_id) do
    return
    |> Return.transition_changeset(new_status, actor_id)
    |> Repo.update()
  end

  @spec restock_items(Return.t()) :: :ok
  defp restock_items(return) do
    Enum.each(return.items, fn item ->
      StockLevel.adjust(item.sku, item.quantity)
    end)

    {:ok, :restocked}
  end

  @spec notify_customer(Return.t(), atom()) :: {:ok, term()}
  defp notify_customer(return, event_type) do
    Dispatcher.dispatch(%{
      channels: [:email],
      recipient_email: return.customer_email,
      subject: "Return update: #{humanise(event_type)}",
      body: "Your return #{return.id} has been updated.",
      id: "#{return.id}_#{event_type}"
    })

    {:ok, :notified}
  end

  @spec unwrap_result({:ok, map()} | {:error, atom(), term(), map()}) ::
          {:ok, Return.t()} | {:error, atom(), term(), map()}
  defp unwrap_result({:ok, %{return: r}}), do: {:ok, r}
  defp unwrap_result({:error, _, _, _} = error), do: error

  @spec humanise(atom()) :: String.t()
  defp humanise(atom), do: atom |> to_string() |> String.replace("_", " ")
end
```
