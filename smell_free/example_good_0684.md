```elixir
defmodule AppWeb.Schema.Subscriptions do
  @moduledoc """
  Absinthe subscription definitions and topic resolution for real-time
  GraphQL events. Each subscription field declares its topic function,
  which determines which clients receive a given broadcast.
  """

  use Absinthe.Schema.Notation

  object :subscription do
    @desc "Receive live updates when an order changes status."
    field :order_status_changed, :order do
      arg :order_id, non_null(:id)

      config fn args, %{context: %{account: account}} ->
        {:ok, topic: "order:#{args.order_id}:account:#{account.id}"}
      end

      resolve fn order, _args, _info -> {:ok, order} end
    end

    @desc "Receive notifications when new messages arrive in a conversation."
    field :message_received, :message do
      arg :conversation_id, non_null(:id)

      config fn args, %{context: %{account: account}} ->
        {:ok, topic: "conversation:#{args.conversation_id}:member:#{account.id}"}
      end

      resolve fn message, _args, _info -> {:ok, message} end
    end

    @desc "Receive workspace-level events such as member joins or leaves."
    field :workspace_event, :workspace_event do
      arg :workspace_id, non_null(:id)

      config fn args, %{context: %{account: account}} ->
        if Workspaces.member?(args.workspace_id, account.id) do
          {:ok, topic: "workspace:#{args.workspace_id}"}
        else
          {:error, "not a workspace member"}
        end
      end

      resolve fn event, _args, _info -> {:ok, event} end
    end
  end
end

defmodule AppWeb.SubscriptionPublisher do
  @moduledoc """
  Publishes domain events to the Absinthe subscription system.

  Wrap this module's functions in your context or event handler to notify
  GraphQL subscribers when business state changes. Each function resolves
  the correct topic pattern and publishes the payload to all matching clients.
  """

  alias Absinthe.Subscription

  @endpoint AppWeb.Endpoint

  @doc "Notifies subscribers when an order's status changes."
  @spec publish_order_status(map()) :: :ok
  def publish_order_status(%{id: order_id, account_id: account_id} = order) do
    topic = "order:#{order_id}:account:#{account_id}"
    Subscription.publish(@endpoint, order, order_status_changed: topic)
    :ok
  end

  @doc "Notifies conversation members when a new message is created."
  @spec publish_message(map(), [pos_integer()]) :: :ok
  def publish_message(%{conversation_id: conv_id} = message, member_ids)
      when is_list(member_ids) do
    Enum.each(member_ids, fn member_id ->
      topic = "conversation:#{conv_id}:member:#{member_id}"
      Subscription.publish(@endpoint, message, message_received: topic)
    end)

    :ok
  end

  @doc "Broadcasts a workspace-level event to all workspace members."
  @spec publish_workspace_event(map()) :: :ok
  def publish_workspace_event(%{workspace_id: workspace_id} = event) do
    topic = "workspace:#{workspace_id}"
    Subscription.publish(@endpoint, event, workspace_event: topic)
    :ok
  end
end

defmodule AppWeb.SubscriptionAuth do
  @moduledoc """
  Authenticates WebSocket connections for Absinthe subscriptions.
  Called by the Absinthe socket during the connection handshake.
  """

  alias Storefront.Auth.TokenVerifier
  alias Storefront.Accounts

  @doc """
  Validates the Bearer token provided in the connection params and injects
  the account into the Absinthe context. Returns `{:ok, context}` or
  `{:error, reason}`.
  """
  @spec authenticate(map()) :: {:ok, map()} | {:error, String.t()}
  def authenticate(%{"token" => token}) when is_binary(token) do
    with {:ok, %{account_id: account_id}} <- TokenVerifier.verify(token),
         {:ok, account} <- Accounts.fetch(account_id) do
      {:ok, %{account: account}}
    else
      _ -> {:error, "invalid token"}
    end
  end

  def authenticate(_params), do: {:error, "missing token"}
end
```
