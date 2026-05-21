# Annotated Example — Code Smell

## Metadata

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `EmailAddress.parse!/1`
- **Affected function(s):** `EmailAddress.parse!/1`, `NotificationDispatcher.dispatch/2`
- **Short explanation:** `EmailAddress.parse!/1` is the *only* public function for parsing email addresses; it raises an `ArgumentError` when the format is invalid. Because the library provides no `parse/1` variant returning `{:ok, address} | {:error, reason}`, clients like `NotificationDispatcher.dispatch/2` must use `try/rescue` to handle what is a completely ordinary validation scenario. The smell is the absence of a non-raising counterpart, which forces exception-based control-flow on all callers.

---

## Code

```elixir
defmodule EmailAddress do
  @moduledoc """
  Parses and normalises RFC-5321 email addresses for use across the
  notification subsystem.
  """

  @enforce_keys [:local, :domain]
  defstruct [:local, :domain, :display_name]

  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because parse!/1 is the only parsing entry point.
  # VALIDATION: Invalid email addresses are a routine input in any notification
  # VALIDATION: system (user-supplied data is often malformed). By exclusively
  # VALIDATION: raising ArgumentError with no {:ok, _} | {:error, _} counterpart,
  # VALIDATION: all callers are forced into try/rescue for ordinary validation
  # VALIDATION: logic. A parse/1 returning tagged tuples should also exist.
  def parse!(raw, opts \\ []) do
    display_name = Keyword.get(opts, :display_name)
    trimmed = String.trim(raw)

    if String.length(trimmed) == 0 do
      raise ArgumentError, "Email address cannot be blank"
    end

    unless Regex.match?(@email_regex, trimmed) do
      raise ArgumentError, "Invalid email address format: #{inspect(trimmed)}"
    end

    [local | rest] = String.split(trimmed, "@")
    domain = List.first(rest)

    if String.length(local) > 64 do
      raise ArgumentError,
        "Local part exceeds 64 characters: #{String.length(local)} chars"
    end

    if String.length(domain) > 255 do
      raise ArgumentError,
        "Domain part exceeds 255 characters: #{String.length(domain)} chars"
    end

    %__MODULE__{
      local: String.downcase(local),
      domain: String.downcase(domain),
      display_name: display_name
    }
  end
  # VALIDATION: SMELL END

  def to_string(%__MODULE__{local: l, domain: d, display_name: nil}),
    do: "#{l}@#{d}"

  def to_string(%__MODULE__{local: l, domain: d, display_name: name}),
    do: "#{name} <#{l}@#{d}>"
end

defmodule NotificationDispatcher do
  @moduledoc """
  Dispatches email notifications for transactional events such as
  account confirmations, password resets, and order updates.
  """

  require Logger

  alias EmailAddress

  @from_address "notifications@myapp.io"
  @from_display "MyApp Notifications"

  def dispatch(event, recipient_data) do
    raw_email = Map.get(recipient_data, :email, "")

    # Forced to use try/rescue because EmailAddress.parse!/1 raises on invalid
    # input and no non-raising alternative exists.
    try do
      address = EmailAddress.parse!(raw_email, display_name: recipient_data[:name])
      body = build_body(event, recipient_data)

      envelope = %{
        from: EmailAddress.to_string(%EmailAddress{
          local: "notifications",
          domain: "myapp.io",
          display_name: @from_display
        }),
        to: EmailAddress.to_string(address),
        subject: subject_for(event),
        html_body: body,
        metadata: %{event: event, dispatched_at: DateTime.utc_now()}
      }

      deliver(envelope)
    rescue
      e in ArgumentError ->
        Logger.warning(
          "Failed to dispatch #{event} notification: #{e.message} " <>
            "(recipient: #{inspect(recipient_data)})"
        )

        {:error, {:invalid_recipient, e.message}}
    end
  end

  def batch_dispatch(event, recipients) when is_list(recipients) do
    results =
      Enum.map(recipients, fn recipient ->
        {recipient, dispatch(event, recipient)}
      end)

    successes = Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end)
    failures = length(results) - successes

    Logger.info(
      "Batch dispatch complete for #{event}: " <>
        "#{successes} sent, #{failures} failed"
    )

    {:ok, %{results: results, successes: successes, failures: failures}}
  end

  defp subject_for(:account_confirmation), do: "Please confirm your email address"
  defp subject_for(:password_reset), do: "Reset your MyApp password"
  defp subject_for(:order_shipped), do: "Your order is on its way!"
  defp subject_for(event), do: "Notification: #{event}"

  defp build_body(event, data) do
    "<html><body><p>Hello #{Map.get(data, :name, "there")},</p>" <>
      "<p>This is your #{event} notification.</p></body></html>"
  end

  defp deliver(envelope) do
    Logger.info("Delivering email to #{envelope.to} — subject: #{envelope.subject}")
    {:ok, %{message_id: generate_message_id(), envelope: envelope}}
  end

  defp generate_message_id do
    :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
  end
end
```
