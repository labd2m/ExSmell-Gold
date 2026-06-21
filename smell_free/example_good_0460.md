```elixir
defmodule MyApp.Support.AutoResponder do
  @moduledoc """
  Classifies incoming support tickets using a keyword-based rule engine
  and dispatches automatic first-response messages to the appropriate
  template. Classification rules are ordered by priority; the first
  matching rule wins and determines the response template.

  Adding or reordering rules requires only a change to the `@rules` list
  and no modifications to the dispatch or template rendering logic.
  """

  alias MyApp.Support.{Ticket, TicketMessage}
  alias MyApp.Repo
  alias MyApp.Email.TemplateRenderer
  alias MyApp.Mailer

  @type classification :: atom()

  @rules [
    {~w(password reset forgot login credentials), :password_reset},
    {~w(invoice billing charge refund payment), :billing_inquiry},
    {~w(bug error crash broken not working), :bug_report},
    {~w(cancel cancellation terminate subscription), :cancellation},
    {~w(upgrade plan pricing tier), :upgrade_inquiry},
    {~w(slow performance timeout loading speed), :performance_issue}
  ]

  @default_classification :general_inquiry

  @doc """
  Classifies `ticket` based on its subject and body, selects a response
  template, and delivers the auto-response. Returns `{:ok, classification}`
  or `{:error, reason}` when the email cannot be delivered.
  """
  @spec respond(Ticket.t()) :: {:ok, classification()} | {:error, term()}
  def respond(%Ticket{} = ticket) do
    classification = classify(ticket)
    bindings = build_bindings(ticket, classification)

    with {:ok, rendered} <- TemplateRenderer.render("auto_response_#{classification}", bindings),
         {:ok, _message} <- store_message(ticket, rendered.text),
         :ok <- deliver_email(ticket, rendered) do
      {:ok, classification}
    end
  end

  @doc """
  Returns the classification for `ticket` without triggering any side effects.
  """
  @spec classify(Ticket.t()) :: classification()
  def classify(%Ticket{subject: subject, body: body}) do
    text = "#{subject} #{body}" |> String.downcase()

    Enum.find_value(@rules, @default_classification, fn {keywords, label} ->
      if Enum.any?(keywords, &String.contains?(text, &1)), do: label
    end)
  end

  @spec build_bindings(Ticket.t(), classification()) :: keyword()
  defp build_bindings(ticket, classification) do
    [
      ticket_id: ticket.id,
      customer_name: ticket.customer_name,
      subject: ticket.subject,
      classification: classification,
      response_time_hours: expected_response_hours(classification)
    ]
  end

  @spec expected_response_hours(classification()) :: pos_integer()
  defp expected_response_hours(:bug_report), do: 4
  defp expected_response_hours(:billing_inquiry), do: 8
  defp expected_response_hours(:cancellation), do: 2
  defp expected_response_hours(_), do: 24

  @spec store_message(Ticket.t(), String.t()) ::
          {:ok, TicketMessage.t()} | {:error, Ecto.Changeset.t()}
  defp store_message(ticket, content) do
    %TicketMessage{}
    |> TicketMessage.changeset(%{
      ticket_id: ticket.id,
      author_type: :system,
      content: content,
      sent_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  @spec deliver_email(Ticket.t(), map()) :: :ok | {:error, term()}
  defp deliver_email(ticket, rendered) do
    case Mailer.deliver(%{
           to: ticket.customer_email,
           subject: "Re: #{ticket.subject}",
           html_body: rendered.html,
           text_body: rendered.text
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
```
