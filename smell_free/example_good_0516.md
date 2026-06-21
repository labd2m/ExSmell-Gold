```elixir
defmodule MyApp.Support.ConversationRouter do
  @moduledoc """
  Routes incoming support conversations to the appropriate agent queue
  based on ticket category, customer tier, and current queue depths.
  Routing rules are evaluated in priority order; the first matching rule
  determines the target queue.

  Queue depth information is fetched from a supervised `QueueMonitor`
  GenServer that polls the ticketing API on a background interval,
  ensuring routing decisions are based on near-real-time load data
  without blocking individual routing calls.
  """

  alias MyApp.Support.{Ticket, QueueMonitor}

  @type queue_id :: String.t()
  @type route_result :: %{queue_id: queue_id(), reason: String.t()}

  @routing_rules [
    {&__MODULE__.rule_vip_customer/1, "vip_priority"},
    {&__MODULE__.rule_billing_issue/1, "billing_specialists"},
    {&__MODULE__.rule_technical_issue/1, "technical_support"},
    {&__MODULE__.rule_enterprise_tier/1, "enterprise_support"},
    {&__MODULE__.rule_least_loaded/1, "dynamic_load_balance"}
  ]

  @doc """
  Routes `ticket` to a queue by evaluating all routing rules in priority
  order. Always returns a result; falls back to a default queue when no
  rule matches.
  """
  @spec route(Ticket.t()) :: route_result()
  def route(%Ticket{} = ticket) do
    Enum.find_value(@routing_rules, default_route(), fn {rule_fn, queue_id} ->
      if rule_fn.(ticket), do: %{queue_id: queue_id, reason: queue_id}
    end)
  end

  @doc false
  @spec rule_vip_customer(Ticket.t()) :: boolean()
  def rule_vip_customer(%Ticket{customer_tier: :vip}), do: true
  def rule_vip_customer(_), do: false

  @doc false
  @spec rule_billing_issue(Ticket.t()) :: boolean()
  def rule_billing_issue(%Ticket{category: cat}) when cat in [:billing, :payment, :refund],
    do: true

  def rule_billing_issue(_), do: false

  @doc false
  @spec rule_technical_issue(Ticket.t()) :: boolean()
  def rule_technical_issue(%Ticket{category: cat}) when cat in [:bug, :integration, :api],
    do: true

  def rule_technical_issue(_), do: false

  @doc false
  @spec rule_enterprise_tier(Ticket.t()) :: boolean()
  def rule_enterprise_tier(%Ticket{customer_tier: :enterprise}), do: true
  def rule_enterprise_tier(_), do: false

  @doc false
  @spec rule_least_loaded(Ticket.t()) :: boolean()
  def rule_least_loaded(_ticket) do
    case QueueMonitor.least_loaded_queue() do
      {:ok, _queue_id} -> true
      {:error, _} -> false
    end
  end

  @spec default_route() :: route_result()
  defp default_route, do: %{queue_id: "general_support", reason: "default"}
end
```
