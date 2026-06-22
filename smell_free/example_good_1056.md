```elixir
defmodule Webhooks.PayloadDeserialiser do
  @moduledoc """
  Deserialises inbound webhook payloads from external providers into typed
  domain structs. Each provider declares its own version-aware parser module;
  the deserialiser selects the correct parser from the schema version embedded
  in the payload header or body, ensuring backward-compatible parsing as
  providers evolve their event schemas. Unknown versions produce an explicit
  `{:error, :unsupported_version}` rather than silently discarding fields.
  """

  alias Webhooks.Parsers.{Github, Stripe, Sendgrid}

  @type provider :: :github | :stripe | :sendgrid
  @type version :: binary()
  @type raw_payload :: binary()
  @type parsed_event :: struct()

  @parsers %{
    github: Github,
    stripe: Stripe,
    sendgrid: Sendgrid
  }

  @doc """
  Deserialises `raw_payload` from `provider` using the schema version
  detected from `headers`. Returns `{:ok, event_struct}` or
  `{:error, reason}`.
  """
  @spec deserialise(provider(), raw_payload(), map()) ::
          {:ok, parsed_event()} | {:error, term()}
  def deserialise(provider, raw_payload, headers \\ %{})
      when is_atom(provider) and is_binary(raw_payload) and is_map(headers) do
    with {:ok, parser} <- resolve_parser(provider),
         {:ok, body} <- decode_json(raw_payload),
         {:ok, version} <- detect_version(provider, body, headers),
         {:ok, event} <- parser.parse(version, body) do
      {:ok, event}
    end
  end

  @doc """
  Returns the list of supported versions for `provider`.
  """
  @spec supported_versions(provider()) :: [version()]
  def supported_versions(provider) when is_atom(provider) do
    case resolve_parser(provider) do
      {:ok, parser} -> parser.supported_versions()
      {:error, _} -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp resolve_parser(provider) do
    case Map.fetch(@parsers, provider) do
      {:ok, parser} -> {:ok, parser}
      :error -> {:error, {:unknown_provider, provider}}
    end
  end

  defp decode_json(raw) do
    case Jason.decode(raw) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:json_decode_failed, reason}}
    end
  end

  defp detect_version(:stripe, _body, headers) do
    case Map.get(headers, "stripe-version") do
      nil -> {:error, :missing_version_header}
      version -> {:ok, version}
    end
  end

  defp detect_version(:github, _body, headers) do
    case Map.get(headers, "x-github-event") do
      nil -> {:error, :missing_event_header}
      event_type -> {:ok, event_type}
    end
  end

  defp detect_version(:sendgrid, body, _headers) do
    case Map.get(body, "version") do
      nil -> {:ok, "1"}
      version -> {:ok, to_string(version)}
    end
  end

  defp detect_version(provider, _body, _headers) do
    {:error, {:no_version_strategy, provider}}
  end
end

defmodule Webhooks.Parsers.Stripe do
  @moduledoc "Parses Stripe webhook event payloads into domain structs."

  @supported_versions ["2023-10-16", "2022-11-15", "2020-08-27"]

  @spec supported_versions() :: [binary()]
  def supported_versions, do: @supported_versions

  @spec parse(binary(), map()) :: {:ok, struct()} | {:error, term()}
  def parse(version, %{"type" => event_type} = body) when version in @supported_versions do
    case event_type do
      "payment_intent.succeeded" -> parse_payment_intent_succeeded(body)
      "customer.subscription.created" -> parse_subscription_created(body)
      "invoice.payment_failed" -> parse_invoice_payment_failed(body)
      _ -> {:error, {:unhandled_event_type, event_type}}
    end
  end

  def parse(version, _body) when version not in @supported_versions do
    {:error, {:unsupported_version, version}}
  end

  def parse(_version, body) do
    {:error, {:missing_event_type, body}}
  end

  defp parse_payment_intent_succeeded(%{"data" => %{"object" => obj}}) do
    {:ok, %Webhooks.Events.PaymentIntentSucceeded{
      payment_intent_id: obj["id"],
      amount_cents: obj["amount"],
      currency: obj["currency"],
      customer_id: obj["customer"]
    }}
  end

  defp parse_subscription_created(%{"data" => %{"object" => obj}}) do
    {:ok, %Webhooks.Events.SubscriptionCreated{
      subscription_id: obj["id"],
      customer_id: obj["customer"],
      plan_id: get_in(obj, ["items", "data", Access.at(0), "price", "id"]),
      status: obj["status"]
    }}
  end

  defp parse_invoice_payment_failed(%{"data" => %{"object" => obj}}) do
    {:ok, %Webhooks.Events.InvoicePaymentFailed{
      invoice_id: obj["id"],
      customer_id: obj["customer"],
      amount_due_cents: obj["amount_due"],
      attempt_count: obj["attempt_count"]
    }}
  end
end
```
