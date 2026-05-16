# Annotated Example 18

## Metadata

- **Smell name:** Accessing non-existent Map/Struct fields
- **Expected smell location:** `Support.TicketRouter.assign/2`, lines where `ticket` map keys are accessed dynamically
- **Affected function(s):** `assign/2`
- **Short explanation:** `ticket[:severity]`, `ticket[:category]`, `ticket[:language]`, and `ticket[:vip]` use dynamic bracket access. A missing `:severity` silently returns `nil`, which falls through the priority routing `cond` to a default branch, potentially routing a critical ticket to a general queue rather than raising a missing-field error.

---

```elixir
defmodule Support.TicketRouter do
  @moduledoc """
  Routes incoming support tickets to the appropriate agent queue based
  on severity, product category, language, and customer tier.
  """

  require Logger

  @queues %{
    critical:       "queue:critical",
    billing:        "queue:billing",
    technical:      "queue:technical",
    vip_general:    "queue:vip_general",
    general:        "queue:general",
    international:  "queue:international"
  }

  @supported_languages ~w(en es pt fr de)
  @valid_severities    [:low, :medium, :high, :critical]
  @valid_categories    [:billing, :technical, :account, :general]

  @type routing_result :: %{
          queue: String.t(),
          estimated_wait_minutes: integer(),
          assigned_at: DateTime.t()
        }

  @spec assign(map(), list(map())) :: {:ok, routing_result()} | {:error, String.t()}
  def assign(ticket, available_agents) do
    # VALIDATION: SMELL START - Accessing non-existent Map/Struct fields
    # VALIDATION: This is a smell because `ticket[:severity]`,
    # `ticket[:category]`, `ticket[:language]`, and `ticket[:vip]` use
    # dynamic bracket access on a plain map. When `:severity` is absent,
    # `nil` is returned and evaluated inside the routing `cond`; none of the
    # severity-based clauses match `nil`, so the ticket silently falls through
    # to the `:general` queue instead of raising an error about the malformed
    # ticket. A missing `:vip` similarly silently disables the VIP fast-lane.
    severity = ticket[:severity]
    category = ticket[:category]
    language = ticket[:language]
    vip      = ticket[:vip]
    # VALIDATION: SMELL END

    with :ok <- validate_severity(severity),
         :ok <- validate_category(category) do
      queue          = select_queue(severity, category, language, vip)
      estimated_wait = estimate_wait(queue, available_agents)

      result = %{
        queue: queue,
        estimated_wait_minutes: estimated_wait,
        assigned_at: DateTime.utc_now()
      }

      Logger.info("Ticket routed",
        ticket_id: Map.get(ticket, :id),
        queue: queue,
        severity: severity,
        vip: vip,
        estimated_wait_minutes: estimated_wait
      )

      {:ok, result}
    end
  end

  @spec list_queues() :: list(String.t())
  def list_queues, do: Map.values(@queues)

  # ── Routing logic ────────────────────────────────────────────────────────────

  defp select_queue(severity, category, language, vip) do
    cond do
      severity == :critical ->
        @queues[:critical]

      category == :billing ->
        @queues[:billing]

      vip == true ->
        @queues[:vip_general]

      language not in @supported_languages && language != nil ->
        @queues[:international]

      category == :technical ->
        @queues[:technical]

      true ->
        @queues[:general]
    end
  end

  defp estimate_wait(queue, available_agents) do
    agents_in_queue =
      Enum.count(available_agents, fn a -> a.assigned_queue == queue && a.available end)

    base_wait = 15

    if agents_in_queue > 0 do
      max(1, div(base_wait, agents_in_queue))
    else
      base_wait * 3
    end
  end

  # ── Validators ──────────────────────────────────────────────────────────────

  defp validate_severity(nil), do: {:error, "Ticket severity is required"}

  defp validate_severity(s) when s in @valid_severities, do: :ok

  defp validate_severity(s),
    do: {:error, "Invalid severity: #{inspect(s)}. Valid: #{inspect(@valid_severities)}"}

  defp validate_category(nil), do: {:error, "Ticket category is required"}

  defp validate_category(c) when c in @valid_categories, do: :ok

  defp validate_category(c),
    do: {:error, "Invalid category: #{inspect(c)}. Valid: #{inspect(@valid_categories)}"}
end
```
