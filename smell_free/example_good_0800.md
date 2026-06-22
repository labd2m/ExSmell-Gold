```elixir
defmodule MyApp.Marketplace.SellerOnboarding do
  @moduledoc """
  Orchestrates the multi-step seller onboarding flow: validating business
  details, provisioning a Stripe Connect account, creating the seller
  record, and sending a welcome email. The flow uses `Ecto.Multi` for
  the database writes and wraps the external Stripe call in a compensating
  action that deactivates the Connect account if the local transaction
  subsequently fails.
  """

  alias Ecto.Multi
  alias MyApp.Repo
  alias MyApp.Marketplace.{Seller, SellerProfile}
  alias MyApp.Integrations.StripeConnect
  alias MyApp.Mailer

  @type onboarding_params :: %{
          required(:business_name) => String.t(),
          required(:email) => String.t(),
          required(:country) => String.t(),
          required(:business_type) => :individual | :company,
          optional(:website_url) => String.t(),
          optional(:description) => String.t()
        }

  @doc """
  Runs the full seller onboarding flow for `params`. Returns
  `{:ok, seller}` on success or a descriptive error tuple.
  """
  @spec onboard(onboarding_params()) ::
          {:ok, Seller.t()}
          | {:error, :stripe_provisioning_failed, term()}
          | {:error, atom(), term(), map()}
  def onboard(params) when is_map(params) do
    with :ok <- validate_params(params),
         {:ok, connect_account_id} <- provision_stripe_account(params) do
      run_transaction(params, connect_account_id)
      |> handle_transaction_result(connect_account_id)
    end
  end

  @spec validate_params(onboarding_params()) :: :ok | {:error, :validation_failed, [String.t()]}
  defp validate_params(params) do
    errors =
      []
      |> check_required(params, :business_name, "Business name is required")
      |> check_required(params, :email, "Email is required")
      |> check_required(params, :country, "Country is required")
      |> check_email_format(params)

    if errors == [], do: :ok, else: {:error, :validation_failed, errors}
  end

  @spec provision_stripe_account(onboarding_params()) ::
          {:ok, String.t()} | {:error, :stripe_provisioning_failed, term()}
  defp provision_stripe_account(params) do
    case StripeConnect.create_account(%{
           email: params.email,
           country: params.country,
           business_type: params.business_type,
           capabilities: %{card_payments: %{requested: true}, transfers: %{requested: true}}
         }) do
      {:ok, %{id: account_id}} -> {:ok, account_id}
      {:error, reason} -> {:error, :stripe_provisioning_failed, reason}
    end
  end

  @spec run_transaction(onboarding_params(), String.t()) ::
          {:ok, map()} | {:error, atom(), term(), map()}
  defp run_transaction(params, connect_account_id) do
    Multi.new()
    |> Multi.run(:seller, fn _repo, _ ->
      %Seller{}
      |> Seller.changeset(%{
        email: params.email,
        stripe_connect_account_id: connect_account_id,
        status: :pending_verification
      })
      |> Repo.insert()
    end)
    |> Multi.run(:profile, fn _repo, %{seller: seller} ->
      %SellerProfile{}
      |> SellerProfile.changeset(%{
        seller_id: seller.id,
        business_name: params.business_name,
        country: params.country,
        business_type: params.business_type,
        website_url: Map.get(params, :website_url),
        description: Map.get(params, :description)
      })
      |> Repo.insert()
    end)
    |> Repo.transaction()
  end

  @spec handle_transaction_result(
          {:ok, map()} | {:error, atom(), term(), map()},
          String.t()
        ) :: {:ok, Seller.t()} | {:error, atom(), term(), map()}
  defp handle_transaction_result({:ok, %{seller: seller}}, _connect_id) do
    deliver_welcome_email(seller)
    {:ok, seller}
  end

  defp handle_transaction_result({:error, _step, _reason, _changes} = error, connect_id) do
    deactivate_stripe_account(connect_id)
    error
  end

  @spec deliver_welcome_email(Seller.t()) :: :ok
  defp deliver_welcome_email(seller) do
    case Mailer.deliver_seller_welcome(seller) do
      {:ok, _} -> :ok
      {:error, reason} ->
        require Logger
        Logger.warning("seller_welcome_email_failed", seller_id: seller.id, reason: inspect(reason))
    end
  end

  @spec deactivate_stripe_account(String.t()) :: :ok
  defp deactivate_stripe_account(connect_id) do
    StripeConnect.deactivate_account(connect_id)
    :ok
  end

  @spec check_required(
          [String.t()],
          map(),
          atom(),
          String.t()
        ) :: [String.t()]
  defp check_required(errors, params, key, message) do
    val = Map.get(params, key)
    if is_nil(val) or val == "", do: [message | errors], else: errors
  end

  @spec check_email_format([String.t()], map()) :: [String.t()]
  defp check_email_format(errors, %{email: email}) when is_binary(email) do
    if String.match?(email, ~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/),
      do: errors,
      else: ["Email is not a valid address" | errors]
  end

  defp check_email_format(errors, _), do: errors
end
```
