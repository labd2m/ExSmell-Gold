```elixir
defmodule MyApp.Emails do
  @moduledoc """
  Centralises all transactional email construction for the application.
  Each function returns a fully composed `Swoosh.Email` struct ready for
  delivery. Template rendering is delegated to HEEx components, keeping
  view logic separate from addressing and subject logic. No email is
  sent from within this module — that is the responsibility of the caller
  or a background worker.
  """

  import Swoosh.Email

  alias MyApp.Mailer
  alias MyAppWeb.EmailComponents

  @from_address {"MyApp Notifications", "no-reply@myapp.example"}

  @doc """
  Builds a welcome email for a newly registered user.
  """
  @spec welcome(map()) :: Swoosh.Email.t()
  def welcome(%{email: address, name: name, confirmation_token: token}) do
    confirmation_url = MyAppWeb.Router.Helpers.user_confirmation_url(
      MyAppWeb.Endpoint, :confirm, token
    )

    new()
    |> from(@from_address)
    |> to({name, address})
    |> subject("Welcome to MyApp — confirm your email")
    |> html_body(render_html(:welcome, name: name, confirmation_url: confirmation_url))
    |> text_body(render_text(:welcome, name: name, confirmation_url: confirmation_url))
  end

  @doc """
  Builds a password reset email.
  """
  @spec password_reset(map()) :: Swoosh.Email.t()
  def password_reset(%{email: address, name: name, reset_token: token}) do
    reset_url = MyAppWeb.Router.Helpers.user_reset_password_url(
      MyAppWeb.Endpoint, :edit, token
    )

    new()
    |> from(@from_address)
    |> to({name, address})
    |> subject("Reset your MyApp password")
    |> html_body(render_html(:password_reset, name: name, reset_url: reset_url))
    |> text_body(render_text(:password_reset, name: name, reset_url: reset_url))
  end

  @doc """
  Builds an invoice delivery email with a PDF attachment.
  """
  @spec invoice(map(), binary()) :: Swoosh.Email.t()
  def invoice(%{email: address, name: name, invoice: invoice}, pdf_binary)
      when is_binary(pdf_binary) do
    filename = "invoice_#{invoice.number}.pdf"

    new()
    |> from(@from_address)
    |> to({name, address})
    |> subject("Your invoice #{invoice.number} from MyApp")
    |> html_body(render_html(:invoice, name: name, invoice: invoice))
    |> text_body(render_text(:invoice, name: name, invoice: invoice))
    |> attachment(%Swoosh.Attachment{
      filename: filename,
      content_type: "application/pdf",
      data: pdf_binary
    })
  end

  @doc """
  Builds a team invitation email.
  """
  @spec team_invitation(map()) :: Swoosh.Email.t()
  def team_invitation(%{
        invitee_email: address,
        inviter_name: inviter,
        team_name: team,
        invitation_token: token
      }) do
    accept_url = MyAppWeb.Router.Helpers.invitation_url(
      MyAppWeb.Endpoint, :accept, token
    )

    new()
    |> from(@from_address)
    |> to(address)
    |> subject("#{inviter} invited you to join #{team} on MyApp")
    |> html_body(render_html(:team_invitation,
         inviter_name: inviter, team_name: team, accept_url: accept_url))
    |> text_body(render_text(:team_invitation,
         inviter_name: inviter, team_name: team, accept_url: accept_url))
  end

  @doc """
  Delivers `email` synchronously. For background delivery wrap in an
  Oban worker instead of calling this directly from a controller.
  Returns `{:ok, receipt}` or `{:error, reason}`.
  """
  @spec deliver(Swoosh.Email.t()) :: {:ok, term()} | {:error, term()}
  def deliver(%Swoosh.Email{} = email) do
    Mailer.deliver(email)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp render_html(template, assigns) do
    EmailComponents.render_to_html(template, assigns)
  end

  defp render_text(template, assigns) do
    EmailComponents.render_to_text(template, assigns)
  end
end
```
