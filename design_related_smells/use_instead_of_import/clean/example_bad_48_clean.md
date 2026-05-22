```elixir
defmodule RegexPatterns do
  @email_regex    ~r/^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$/
  @phone_regex    ~r/^\+?[1-9]\d{7,14}$/
  @username_regex ~r/^[a-zA-Z0-9_]{3,32}$/
  @zip_regex      ~r/^\d{5}(-\d{4})?$/

  def valid_email?(str),    do: Regex.match?(@email_regex, str)
  def valid_phone?(str),    do: Regex.match?(@phone_regex, str)
  def valid_username?(str), do: Regex.match?(@username_regex, str)
  def valid_zip?(str),      do: Regex.match?(@zip_regex, str)
end

defmodule ValidationHelpers do
  defmacro __using__(_opts) do
    quote do
      import RegexPatterns

      def required(value, field) do
        if is_nil(value) or value == "",
          do: {:error, "#{field} is required"},
          else: :ok
      end

      def min_length(str, min, field) do
        if String.length(str) < min,
          do: {:error, "#{field} must be at least #{min} characters"},
          else: :ok
      end

      def max_length(str, max, field) do
        if String.length(str) > max,
          do: {:error, "#{field} must be at most #{max} characters"},
          else: :ok
      end

      def collect_errors(validations) do
        validations
        |> Enum.filter(&match?({:error, _}, &1))
        |> Enum.map(fn {:error, msg} -> msg end)
      end
    end
  end
end

defmodule UserRegistrationService do
  use ValidationHelpers

  @min_password_length 8
  @max_username_length 32
  @allowed_roles       ~w(admin editor viewer)

  def register(params) do
    errors = collect_errors([
      required(params[:email],    "email"),
      required(params[:username], "username"),
      required(params[:password], "password"),
      validate_email(params[:email]    || ""),
      validate_username(params[:username] || ""),
      validate_password(params[:password] || ""),
      validate_role(params[:role])
    ])

    if Enum.empty?(errors) do
      {:ok, build_user(params)}
    else
      {:error, errors}
    end
  end

  def update_profile(user, params) do
    field_errors =
      Enum.flat_map(params, fn
        {:email,    v} -> collect_errors([validate_email(v)])
        {:username, v} -> collect_errors([validate_username(v)])
        {:phone,    v} -> collect_errors([validate_phone_number(v)])
        {:zip,      v} -> collect_errors([validate_zip_code(v)])
        _              -> []
      end)

    if Enum.empty?(field_errors) do
      {:ok, Map.merge(user, params)}
    else
      {:error, field_errors}
    end
  end

  def validate_email(email) do
    if valid_email?(email),
      do: :ok,
      else: {:error, "Invalid email address format"}
  end

  def validate_phone_number(phone) do
    if valid_phone?(phone),
      do: :ok,
      else: {:error, "Invalid phone number format"}
  end

  def validate_zip_code(zip) do
    if valid_zip?(zip),
      do: :ok,
      else: {:error, "Invalid ZIP code"}
  end

  defp validate_username(username) do
    collect_errors([
      min_length(username, 3,  "username"),
      max_length(username, @max_username_length, "username"),
      if valid_username?(username), do: :ok, else: {:error, "Username may only contain letters, numbers, and underscores"}
    ])
    |> case do
      []     -> :ok
      [h | _] -> {:error, h}
    end
  end

  defp validate_password(password) do
    min_length(password, @min_password_length, "password")
  end

  defp validate_role(nil), do: :ok
  defp validate_role(role) do
    if role in @allowed_roles,
      do: :ok,
      else: {:error, "Role must be one of: #{Enum.join(@allowed_roles, ", ")}"}
  end

  defp build_user(params) do
    %{
      id:           :erlang.unique_integer([:positive]),
      email:        String.downcase(params[:email]),
      username:     params[:username],
      role:         params[:role] || "viewer",
      inserted_at:  DateTime.utc_now(),
      confirmed:    false
    }
  end
end
```
