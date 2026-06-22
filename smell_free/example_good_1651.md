```elixir
defmodule Api.Resolvers.Orders do
  @moduledoc """
  GraphQL field resolvers for the Order domain.
  Batch loading is delegated to the Dataloader source to avoid N+1 queries.
  All resolver functions return tagged result tuples compatible with Absinthe's
  resolution protocol.
  """

  alias Api.Resolvers.Orders.{Loader, Authorizer}
  alias Orders.{Context, Aggregate}

  @doc """
  Resolves a single order by ID for the authenticated actor.
  """
  @spec get_order(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, String.t()}
  def get_order(_parent, %{id: order_id}, %{context: ctx}) when is_binary(order_id) do
    with :ok <- authorize_read(ctx.current_user, order_id),
         {:ok, order} <- fetch_order(order_id) do
      {:ok, order}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def get_order(_, _, _), do: {:error, "invalid arguments"}

  @doc """
  Resolves a paginated list of orders for the authenticated user.
  """
  @spec list_orders(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, String.t()}
  def list_orders(_parent, args, %{context: ctx}) do
    page          = Map.get(args, :page, 1)
    per_page      = Map.get(args, :per_page, 20)
    status_filter = Map.get(args, :status)

    orders = Context.list_for_customer(ctx.current_user.id,
      page: page,
      per_page: per_page,
      status: status_filter
    )

    total = Context.count_for_customer(ctx.current_user.id, status: status_filter)

    {:ok, %{nodes: orders, total: total, page: page, per_page: per_page}}
  end

  @doc """
  Resolves line items for an order using the batch loader.
  """
  @spec line_items(map(), map(), Absinthe.Resolution.t()) :: {:middleware, term(), term()}
  def line_items(%{id: order_id}, _args, resolution) do
    Absinthe.Resolution.put_result(resolution, Loader.load_line_items(order_id))
  end

  @doc """
  Places a new order for the authenticated user.
  """
  @spec place_order(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, String.t()}
  def place_order(_parent, %{input: input}, %{context: ctx}) do
    with {:ok, validated_input} <- validate_place_input(input),
         {:ok, order} <- submit_order(ctx.current_user.id, validated_input) do
      {:ok, order}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def place_order(_, _, _), do: {:error, "missing input"}

  @doc """
  Cancels an order on behalf of the authenticated user.
  """
  @spec cancel_order(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, String.t()}
  def cancel_order(_parent, %{id: order_id, reason: reason}, %{context: ctx})
      when is_binary(order_id) and is_binary(reason) do
    with :ok <- authorize_cancel(ctx.current_user, order_id),
         {:ok, order} <- fetch_order(order_id),
         {:ok, cancelled} <- perform_cancel(order, reason) do
      {:ok, cancelled}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def cancel_order(_, _, _), do: {:error, "invalid arguments"}

  # --- authorization wrappers ---

  @spec authorize_read(map(), String.t()) :: :ok | {:error, String.t()}
  defp authorize_read(current_user, order_id) do
    case Authorizer.can_read_order?(current_user, order_id) do
      :ok -> :ok
      {:error, :unauthorized} -> {:error, "not authorized"}
      {:error, _} -> {:error, "authorization check failed"}
    end
  end

  @spec authorize_cancel(map(), String.t()) :: :ok | {:error, String.t()}
  defp authorize_cancel(current_user, order_id) do
    case Authorizer.can_cancel_order?(current_user, order_id) do
      :ok -> :ok
      {:error, :unauthorized} -> {:error, "not authorized to cancel this order"}
      {:error, _} -> {:error, "authorization check failed"}
    end
  end

  # --- context wrappers ---

  @spec fetch_order(String.t()) :: {:ok, map()} | {:error, String.t()}
  defp fetch_order(order_id) do
    case Context.fetch_order(order_id) do
      {:ok, order} -> {:ok, order}
      {:error, :not_found} -> {:error, "order not found"}
      {:error, _} -> {:error, "failed to fetch order"}
    end
  end

  @spec submit_order(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  defp submit_order(customer_id, validated_input) do
    case Context.place_order(customer_id, validated_input) do
      {:ok, order} -> {:ok, order}
      {:error, %Ecto.Changeset{} = cs} -> {:error, format_changeset_error(cs)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _} -> {:error, "failed to place order"}
    end
  end

  @spec perform_cancel(map(), String.t()) :: {:ok, map()} | {:error, String.t()}
  defp perform_cancel(order, reason) do
    case Context.cancel_order(order, reason) do
      {:ok, cancelled} -> {:ok, cancelled}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, _} -> {:error, "failed to cancel order"}
    end
  end

  # --- input validation ---

  @spec validate_place_input(map()) :: {:ok, map()} | {:error, String.t()}
  defp validate_place_input(%{items: items} = input) when is_list(items) and items != [] do
    {:ok, input}
  end

  defp validate_place_input(_), do: {:error, "order must contain at least one item"}

  # --- formatting ---

  @spec format_changeset_error(Ecto.Changeset.t()) :: String.t()
  defp format_changeset_error(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field} #{msg}" end)
    |> Enum.join(", ")
  end
end
```
