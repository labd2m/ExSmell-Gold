```elixir
defmodule UserManagement.InviteService do
  @moduledoc """
  Handles individual and bulk user invitations for enterprise workspace
  onboarding, enforcing email-domain policies.
  """

  alias UserManagement.{Invitation, User, Workspace, Mailer, Repo, AuditLog}

  @disposable_domains ~w[mailinator.com guerrillamail.com trashmail.com tempmail.org throwam.com]


  @doc """
  Sends a workspace invitation to a single email address.
  """
  def send_invite(email, %Workspace{} = workspace) do
    with {:ok, normalised} <- normalise_email(email),
         {:ok, domain}     <- extract_domain(normalised),
         :ok               <- check_domain_allowed(domain, workspace),
         :ok               <- check_domain_not_disposable(domain) do

      existing = Repo.find_invitation(normalised, workspace.id)

      if existing do
        {:error, :already_invited}
      else
        invite = %Invitation{
          email:        normalised,
          workspace_id: workspace.id,
          token:        generate_token(),
          expires_at:   hours_from_now(48),
          status:       :pending
        }

        case Repo.insert(invite) do
          {:ok, saved} ->
            Mailer.send_workspace_invite(saved, workspace)
            AuditLog.log(:invite_sent, %{email: normalised, workspace: workspace.id})
            {:ok, saved}

          {:error, reason} ->
            {:error, {:db_error, reason}}
        end
      end
    end
  end


  @doc """
  Imports a list of email addresses as pending invitations.
  Returns `{:ok, results}` where results maps each email to its outcome.
  """
  def bulk_import_users(emails, %Workspace{} = workspace) when is_list(emails) do
    results =
      Enum.map(emails, fn raw_email ->
        outcome =
          with {:ok, normalised} <- normalise_email(raw_email),
               {:ok, domain}     <- extract_domain(normalised),
               :ok               <- check_domain_allowed(domain, workspace),
               :ok               <- check_domain_not_disposable(domain) do

            invite = %Invitation{
              email:        normalised,
              workspace_id: workspace.id,
              token:        generate_token(),
              expires_at:   hours_from_now(48),
              status:       :pending
            }

            case Repo.insert(invite) do
              {:ok, saved}       -> {:ok, saved}
              {:error, :conflict} -> {:error, :already_invited}
              {:error, reason}   -> {:error, {:db_error, reason}}
            end
          end

        {raw_email, outcome}
      end)

    AuditLog.log(:bulk_invite_completed, %{
      workspace_id: workspace.id,
      count:        length(emails)
    })

    {:ok, Map.new(results)}
  end


  defp normalise_email(email) do
    trimmed = String.trim(email) |> String.downcase()
    if String.contains?(trimmed, "@"), do: {:ok, trimmed}, else: {:error, :invalid_email}
  end

  defp extract_domain(email) do
    case String.split(email, "@") do
      [_local, domain] -> {:ok, domain}
      _                -> {:error, :invalid_email}
    end
  end

  defp check_domain_allowed(_domain, %Workspace{allowed_domains: []}), do: :ok
  defp check_domain_allowed(domain, %Workspace{allowed_domains: list}) do
    if domain in list, do: :ok, else: {:error, :domain_not_allowed}
  end

  defp check_domain_not_disposable(domain) do
    if domain in @disposable_domains do
      {:error, :disposable_email_domain}
    else
      :ok
    end
  end

  defp generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp hours_from_now(h) do
    DateTime.utc_now() |> DateTime.add(h * 3600, :second)
  end
end
```
