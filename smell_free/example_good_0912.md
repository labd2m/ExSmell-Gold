```elixir
defmodule Commerce.AddressBook do
  @moduledoc """
  Manages saved addresses for customer accounts. Customers may store
  multiple shipping and billing addresses, designate one as their default
  for each type, and reuse them at checkout without re-entering details.
  Address records are soft-deleted to preserve historical order data.
  """

  import Ecto.Query, warn: false

  alias MyApp.Repo
  alias Commerce.{SavedAddress}

  @type customer_id :: String.t()
  @type address_id :: Ecto.UUID.t()
  @type address_type :: :shipping | :billing
  @type address_attrs :: %{
          line1: String.t(),
          city: String.t(),
          country_code: String.t(),
          postal_code: String.t(),
          optional(:line2) => String.t(),
          optional(:state) => String.t(),
          optional(:label) => String.t()
        }

  @doc "Saves a new address for `customer_id` of the given `type`."
  @spec save(customer_id(), address_type(), address_attrs()) ::
          {:ok, SavedAddress.t()} | {:error, Ecto.Changeset.t()}
  def save(customer_id, type, attrs)
      when is_binary(customer_id) and type in [:shipping, :billing] and is_map(attrs) do
    full_attrs = Map.merge(attrs, %{customer_id: customer_id, type: Atom.to_string(type), deleted_at: nil})
    %SavedAddress{} |> SavedAddress.changeset(full_attrs) |> Repo.insert()
  end

  @doc "Lists all active addresses of `type` for `customer_id`."
  @spec list(customer_id(), address_type()) :: [SavedAddress.t()]
  def list(customer_id, type) when is_binary(customer_id) and type in [:shipping, :billing] do
    type_str = Atom.to_string(type)

    from(a in SavedAddress,
      where: a.customer_id == ^customer_id and a.type == ^type_str and is_nil(a.deleted_at),
      order_by: [desc: a.is_default, asc: a.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Sets `address_id` as the default for its type, clearing any existing default
  for that customer and address type.
  """
  @spec set_default(customer_id(), address_id()) :: :ok | {:error, :not_found}
  def set_default(customer_id, address_id) when is_binary(customer_id) and is_binary(address_id) do
    Repo.transaction(fn ->
      case Repo.get_by(SavedAddress, id: address_id, customer_id: customer_id) do
        nil ->
          Repo.rollback(:not_found)

        %SavedAddress{type: type} = address ->
          Repo.update_all(
            from(a in SavedAddress,
              where: a.customer_id == ^customer_id and a.type == ^type
            ),
            set: [is_default: false]
          )

          address |> SavedAddress.changeset(%{is_default: true}) |> Repo.update!()
          :ok
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the default address of `type` for `customer_id`, or `nil`."
  @spec default(customer_id(), address_type()) :: SavedAddress.t() | nil
  def default(customer_id, type) when is_binary(customer_id) and type in [:shipping, :billing] do
    type_str = Atom.to_string(type)

    Repo.one(
      from(a in SavedAddress,
        where: a.customer_id == ^customer_id and a.type == ^type_str
               and a.is_default == true and is_nil(a.deleted_at)
      )
    )
  end

  @doc "Soft-deletes an address, preserving it for historical order references."
  @spec delete(customer_id(), address_id()) :: :ok | {:error, :not_found}
  def delete(customer_id, address_id) when is_binary(customer_id) and is_binary(address_id) do
    case Repo.get_by(SavedAddress, id: address_id, customer_id: customer_id) do
      nil -> {:error, :not_found}
      addr ->
        addr |> SavedAddress.changeset(%{deleted_at: DateTime.utc_now()}) |> Repo.update!()
        :ok
    end
  end
end
```
