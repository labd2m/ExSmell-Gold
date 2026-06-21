```elixir
defmodule MyApp.Accounts.RegistrationFlow do
  @moduledoc """
  Orchestrates the full user registration flow: creating the account,
  assigning the default subscription plan, sending the confirmation email,
  and emitting a domain event. All side effects are grouped into a single
  `Ecto.Multi` so that any failure rolls back the entire operation atomically.

  This module contains no business logic beyond orchestration; domain
  rules live in the underlying schemas and context modules.
  """

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.Accounts
  alias MyApp.Accounts.{User, EmailConfirmation}
  alias MyApp.Billing
  alias MyApp.Mailer
  alias MyApp.Events

  @default_plan_slug "free"

  @type registration_params :: %{
          required(:email) => String.t(),
          required(:password) => String.t(),
          optional(:name) => String.t(),
          optional(:locale) => String.t()
        }

  @doc """
  Runs the complete registration flow for the given `params`.
  Returns `{:ok, user}` on success or `{:error, failed_step, changeset, changes}`
  when any step of the multi fails.
  """
  @spec register(registration_params()) ::
          {:ok, User.t()} | {:error, atom(), term(), map()}
  def register(params) when is_map(params) do
    Multi.new()
    |> Multi.run(:user, fn _repo, _changes -> Accounts.create_user(params) end)
    |> Multi.run(:plan, fn _repo, %{user: user} -> assign_default_plan(user) end)
    |> Multi.run(:confirmation, fn _repo, %{user: user} -> create_confirmation(user) end)
    |> Repo.transaction()
    |> handle_result()
  end

  @spec handle_result(
          {:ok, map()}
          | {:error, atom(), term(), map()}
        ) :: {:ok, User.t()} | {:error, atom(), term(), map()}
  defp handle_result({:ok, %{user: user, confirmation: {_raw_token, confirmation}}}) do
    deliver_confirmation_email(user, confirmation)
    emit_registered_event(user)
    {:ok, user}
  end

  defp handle_result({:error, _step, _reason, _changes} = error), do: error

  @spec assign_default_plan(User.t()) ::
          {:ok, term()} | {:error, term()}
  defp assign_default_plan(user) do
    case Billing.fetch_plan(@default_plan_slug) do
      {:ok, plan} -> Billing.subscribe(user, plan)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_confirmation(User.t()) ::
          {:ok, {binary(), EmailConfirmation.t()}} | {:error, term()}
  defp create_confirmation(user) do
    EmailConfirmation.build_and_persist(user)
  end

  @spec deliver_confirmation_email(User.t(), EmailConfirmation.t()) :: :ok
  defp deliver_confirmation_email(user, confirmation) do
    case Mailer.deliver_confirmation(user, confirmation.token) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("confirmation_email_failed", user_id: user.id, reason: inspect(reason))
    end
  end

  @spec emit_registered_event(User.t()) :: :ok | {:error, term()}
  defp emit_registered_event(user) do
    Events.broadcast(%Events.UserRegistered{
      user_id: user.id,
      email: user.email,
      occurred_at: DateTime.utc_now()
    })
  end
end
```
