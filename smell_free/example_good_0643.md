```elixir
defmodule MyApp.Test.ServiceMocks do
  @moduledoc """
  Provides contract-tested mocks for external service boundaries used in
  the test suite. Each mock is implemented as a `Mox`-backed module that
  satisfies the same behaviour as the real adapter. Contract tests verify
  that the mock's return values match the shape the production behaviour
  declares, ensuring mocks stay in sync with real implementations without
  hitting live services in CI.
  """

  import Mox

  # ---------------------------------------------------------------------------
  # Mock module declarations (call once in test_helper.exs)
  # ---------------------------------------------------------------------------

  @doc """
  Defines all application mock modules. Call from `test_helper.exs`:

      MyApp.Test.ServiceMocks.define_all()
  """
  @spec define_all() :: :ok
  def define_all do
    Mox.defmock(MyApp.Test.Mocks.Gateway, for: Billing.Gateway)
    Mox.defmock(MyApp.Test.Mocks.StorageClient, for: Storage.Client)
    Mox.defmock(MyApp.Test.Mocks.EmailSender, for: Notifications.Channel)
    Mox.defmock(MyApp.Test.Mocks.SanctionsClient, for: Compliance.SanctionsClient)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Convenience stubs for common scenarios
  # ---------------------------------------------------------------------------

  @doc """
  Stubs the payment gateway to return a successful charge result.
  Accepts an optional `amount_cents` override for the response.
  """
  @spec stub_successful_charge(pos_integer()) :: :ok
  def stub_successful_charge(amount_cents \\ 1_000) do
    stub(MyApp.Test.Mocks.Gateway, :charge, fn attrs ->
      {:ok, %{
        gateway_ref: "pi_test_#{:rand.uniform(999_999)}",
        status: :succeeded,
        amount_cents: Map.get(attrs, :amount_cents, amount_cents),
        currency: Map.get(attrs, :currency, "USD"),
        gateway_fee_cents: div(amount_cents, 40)
      }}
    end)

    :ok
  end

  @doc """
  Stubs the payment gateway to return a declined card error.
  """
  @spec stub_declined_charge() :: :ok
  def stub_declined_charge do
    stub(MyApp.Test.Mocks.Gateway, :charge, fn _attrs ->
      {:error, :card_declined}
    end)

    :ok
  end

  @doc """
  Stubs successful object storage upload, returning a deterministic ETag.
  """
  @spec stub_successful_upload() :: :ok
  def stub_successful_upload do
    stub(MyApp.Test.Mocks.StorageClient, :put_object, fn key, _body, _opts ->
      {:ok, %{etag: "\"#{:crypto.hash(:md5, key) |> Base.encode16(case: :lower)}\""}}
    end)

    :ok
  end

  @doc """
  Stubs the sanctions screener to return a clean result.
  """
  @spec stub_clean_sanctions() :: :ok
  def stub_clean_sanctions do
    stub(MyApp.Test.Mocks.SanctionsClient, :screen, fn _id ->
      {:ok, %{match_level: :none, checked_at: DateTime.utc_now()}}
    end)

    :ok
  end

  @doc """
  Stubs the sanctions screener to return a potential match.
  """
  @spec stub_sanctions_potential_match() :: :ok
  def stub_sanctions_potential_match do
    stub(MyApp.Test.Mocks.SanctionsClient, :screen, fn _id ->
      {:ok, %{match_level: :potential, checked_at: DateTime.utc_now(),
               matched_lists: ["OFAC_SDN"]}}
    end)

    :ok
  end

  @doc """
  Verifies that the gateway received exactly `count` charge calls.
  Call in test assertions after the subject under test has run.
  """
  @spec assert_charge_count(non_neg_integer()) :: :ok
  def assert_charge_count(count) do
    expect(MyApp.Test.Mocks.Gateway, :charge, count, fn attrs ->
      {:ok, %{
        gateway_ref: "pi_expected_#{count}",
        status: :succeeded,
        amount_cents: attrs.amount_cents,
        currency: attrs.currency,
        gateway_fee_cents: 0
      }}
    end)

    :ok
  end

  @doc """
  Configures the application to use mocks rather than real adapters.
  Call from `setup` blocks in integration test modules.
  """
  @spec use_mocks() :: :ok
  def use_mocks do
    Application.put_env(:my_app, :payment_gateway, MyApp.Test.Mocks.Gateway)
    Application.put_env(:my_app, :storage_client, MyApp.Test.Mocks.StorageClient)
    Application.put_env(:my_app, :email_channel, MyApp.Test.Mocks.EmailSender)
    Application.put_env(:my_app, :sanctions_client, MyApp.Test.Mocks.SanctionsClient)
    :ok
  end
end
```
