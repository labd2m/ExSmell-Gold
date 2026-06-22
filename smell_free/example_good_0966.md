```elixir
defmodule MyApp.Integrations.SlackCommandHandler do
  @moduledoc """
  Handles inbound Slack slash-command payloads dispatched by
  `MyApp.Webhooks.Processor`. Each command is routed to a dedicated
  handler function by its command text; unrecognised commands return a
  helpful usage message. All responses follow Slack's ephemeral response
  pattern so replies are visible only to the invoking user.
  """

  require Logger

  alias MyApp.Repo
  alias MyApp.Billing.InvoiceNumberSequence
  alias MyApp.Commerce.Orders
  alias MyApp.Reporting.DashboardMetrics

  @type slack_payload :: %{
          required(:command) => String.t(),
          required(:text) => String.t(),
          required(:user_id) => String.t(),
          required(:user_name) => String.t(),
          optional(:response_url) => String.t()
        }

  @doc """
  Dispatches `payload` to the appropriate command handler and returns
  a Slack-compatible ephemeral response map.
  """
  @spec handle(slack_payload()) :: map()
  def handle(%{command: command, text: text} = payload) do
    args = String.split(String.trim(text))
    dispatch(command, args, payload)
  end

  @spec dispatch(String.t(), [String.t()], slack_payload()) :: map()
  defp dispatch("/order", [order_id], payload) do
    case Orders.fetch(order_id) do
      {:ok, order} ->
        ephemeral("Order *#{order.id}* — Status: `#{order.status}` — Total: #{format_cents(order.total_cents)}")

      {:error, :not_found} ->
        ephemeral(":x: Order `#{order_id}` not found.")
    end
  end

  defp dispatch("/metrics", [], _payload) do
    revenue = DashboardMetrics.gross_revenue(30)
    orders = DashboardMetrics.order_count(30)
    customers = DashboardMetrics.new_customers(30)

    text = """
    *Dashboard — last 30 days*
    • Revenue: #{format_cents(revenue)}
    • Orders: #{orders}
    • New customers: #{customers}
    """

    ephemeral(text)
  end

  defp dispatch("/invoice-next", [], _payload) do
    number = InvoiceNumberSequence.next()
    ephemeral("Next invoice number: *#{number}*")
  end

  defp dispatch(command, _args, %{user_name: user}) do
    Logger.info("slack_command_unrecognised", command: command, user: user)

    ephemeral("""
    :wave: Unknown command `#{command}`. Available commands:
    • `/order <id>` — look up an order
    • `/metrics` — 30-day dashboard summary
    • `/invoice-next` — preview next invoice number
    """)
  end

  @spec ephemeral(String.t()) :: map()
  defp ephemeral(text) do
    %{response_type: "ephemeral", text: String.trim(text)}
  end

  @spec format_cents(non_neg_integer()) :: String.t()
  defp format_cents(cents) do
    dollars = div(cents, 100)
    remainder = String.pad_leading(Integer.to_string(rem(cents, 100)), 2, "0")
    "$#{dollars}.#{remainder}"
  end
end
```
