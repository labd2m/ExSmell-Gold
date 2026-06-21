# Annotated Example 26

- **Smell name:** Using exceptions for control-flow
- **Expected smell location:** `AccountRegistry.create/1` (library) and `RegistrationHandler.handle/1` (client)
- **Affected function(s):** `AccountRegistry.create/1`, `RegistrationHandler.handle/1`
- **Short explanation:** `AccountRegistry.create/1` raises exceptions for duplicate email, weak password, and invalid domain — entirely foreseeable user-input errors that occur regularly during registration. Because no tuple-based alternative is offered, `RegistrationHandler.handle/1` must use `try...rescue` to produce user-facing feedback for what are normal validation outcomes.

```elixir
defmodule AccountRegistry do
  @moduledoc """
  Creates and stores new user accounts.
  Enforces uniqueness, password strength, and domain allow-list constraints.
  """

  defmodule DuplicateEmailError do
    defexception [:message, :email]
  end

  defmodule WeakPasswordError do
    defexception [:message, :violations]
  end

  defmodule DisallowedDomainError do
    defexception [:message, :domain]
  end

  defmodule ValidationError do
    defexception [:message, :field]
  end

  @allowed_domains ~w(example.com acme.org mycompany.io)
  @existing_emails MapSet.new(["alice@example.com", "bob@acme.org"])
  @min_password_length 10

  # VALIDATION: SMELL START - Using exceptions for control-flow
  # VALIDATION: This is a smell because every validation failure during
  # registration — duplicate email, weak password, blocked domain — is a
  # normal, expected user-input outcome. Exposing these only as exceptions
  # forces any registration endpoint to use try...rescue instead of being
  # able to pattern-match on a result tuple.
  def create(%{email: email, password: password, plan: plan}) do
    validate_email_format!(email)
    validate_domain!(email)
    check_duplicate!(email)
    validate_password!(password)
    validate_plan!(plan)

    %{
      id: generate_id(),
      email: email,
      password_hash: hash_password(password),
      plan: plan,
      created_at: DateTime.utc_now(),
      confirmed: false
    }
  end

  def create(_params) do
    raise ValidationError,
      message: "Account creation requires :email, :password, and :plan fields",
      field: :params
  end

  defp validate_email_format!(email) when not is_binary(email) or email == "" do
    raise ValidationError, message: "Email must be a non-empty string", field: :email
  end

  defp validate_email_format!(email) do
    unless String.contains?(email, "@") do
      raise ValidationError, message: "Email '#{email}' is not a valid address", field: :email
    end
  end

  defp validate_domain!(email) do
    domain = email |> String.split("@") |> List.last()

    unless domain in @allowed_domains do
      raise DisallowedDomainError,
        message: "Domain '#{domain}' is not on the allow list",
        domain: domain
    end
  end

  defp check_duplicate!(email) do
    if MapSet.member?(@existing_emails, email) do
      raise DuplicateEmailError,
        message: "An account with email '#{email}' already exists",
        email: email
    end
  end

  defp validate_password!(password) do
    violations =
      []
      |> maybe_add(String.length(password) < @min_password_length, :too_short)
      |> maybe_add(not Regex.match?(~r/[A-Z]/, password), :no_uppercase)
      |> maybe_add(not Regex.match?(~r/[0-9]/, password), :no_digit)

    unless violations == [] do
      raise WeakPasswordError,
        message: "Password does not meet strength requirements: #{inspect(violations)}",
        violations: violations
    end
  end

  defp validate_plan!(plan) when plan not in [:free, :starter, :pro, :enterprise] do
    raise ValidationError,
      message: "Plan '#{inspect(plan)}' is not a valid subscription tier",
      field: :plan
  end

  defp validate_plan!(_plan), do: :ok

  defp maybe_add(list, true, item), do: [item | list]
  defp maybe_add(list, false, _item), do: list

  defp generate_id, do: "usr_#{System.unique_integer([:positive, :monotonic])}"
  defp hash_password(pw), do: :crypto.hash(:sha256, pw) |> Base.encode16()
  # VALIDATION: SMELL END
end

defmodule RegistrationHandler do
  @moduledoc """
  Processes incoming registration requests from the web layer.
  Returns structured results suitable for rendering in the UI.
  """

  require Logger

  def handle(%{"email" => email, "password" => password, "plan" => plan} = _params) do
    Logger.info("Registration attempt for #{email}")

    # VALIDATION: SMELL START - Using exceptions for control-flow
    # VALIDATION: This is a smell because registration validation failures
    # are routine, expected events. The handler must use try...rescue for
    # standard input validation — a task that should be handled with
    # normal conditional or pattern-matching control flow.
    try do
      account =
        AccountRegistry.create(%{
          email: email,
          password: password,
          plan: String.to_existing_atom(plan)
        })

      Logger.info("Account created: #{account.id} for #{email}")
      {:ok, %{account_id: account.id, email: account.email}}
    rescue
      e in AccountRegistry.DuplicateEmailError ->
        {:error, :email_taken, "The address #{e.email} is already registered"}

      e in AccountRegistry.WeakPasswordError ->
        {:error, :weak_password, "Password issues: #{Enum.join(Enum.map(e.violations, &to_string/1), ", ")}"}

      e in AccountRegistry.DisallowedDomainError ->
        {:error, :domain_blocked, "Signups from @#{e.domain} are not permitted"}

      e in AccountRegistry.ValidationError ->
        {:error, :invalid_input, e.message}

      _e in ArgumentError ->
        {:error, :invalid_plan, "Unknown subscription plan '#{plan}'"}
    end
    # VALIDATION: SMELL END
  end

  def handle(_params), do: {:error, :missing_fields, "email, password, and plan are required"}
end
```
