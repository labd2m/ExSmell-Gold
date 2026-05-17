```elixir
defmodule UserManagement.LdapAdapter do
  @moduledoc """
  Adapter for querying user information from the corporate LDAP / Active Directory
  server. Translates raw LDAP entries into internal user structs used across
  the HR and access control systems.
  """

  require Logger

  @ldap_host     Application.compile_env(:user_management, [:ldap, :host], "ldap.internal")
  @ldap_port     Application.compile_env(:user_management, [:ldap, :port], 389)
  @base_dn       Application.compile_env(:user_management, [:ldap, :base_dn], "dc=example,dc=com")
  @bind_dn       Application.compile_env(:user_management, [:ldap, :bind_dn], "")
  @bind_password Application.compile_env(:user_management, [:ldap, :bind_password], "")

  @search_attributes [
    ~c"cn",
    ~c"mail",
    ~c"sAMAccountName",
    ~c"displayName",
    ~c"department",
    ~c"memberOf",
    ~c"telephoneNumber",
    ~c"title"
  ]

  def find_user(username) when is_binary(username) do
    filter = ~c"(sAMAccountName=#{username})"

    with {:ok, conn}           <- connect(),
         {:ok, [{_dn, attrs}]} <- search(conn, filter) do
      {:ok, extract_user(attrs)}
    end
  end

  def find_users_in_department(department) do
    filter = ~c"(department=#{department})"

    with {:ok, conn}    <- connect(),
         {:ok, entries} <- search(conn, filter) do
      users = Enum.map(entries, fn {_dn, attrs} -> extract_user(attrs) end)
      {:ok, users}
    end
  end

  defp extract_user(attrs) when is_list(attrs) do
    cn          = attrs |> Enum.at(0) |> extract_value()
    email       = attrs |> Enum.at(1) |> extract_value()
    username    = attrs |> Enum.at(2) |> extract_value()
    display_name= attrs |> Enum.at(3) |> extract_value()
    department  = attrs |> Enum.at(4) |> extract_value()
    groups      = attrs |> Enum.at(5) |> extract_multi_value()
    phone       = attrs |> Enum.at(6) |> extract_value()
    title       = attrs |> Enum.at(7) |> extract_value()

    %{
      cn:           cn,
      email:        email,
      username:     username,
      display_name: display_name,
      department:   department,
      groups:       groups,
      phone:        phone,
      title:        title
    }
  end

  defp extract_user(_), do: %{}

  defp extract_value({_attr, [value | _]}), do: to_string(value)
  defp extract_value(_), do: nil

  defp extract_multi_value({_attr, values}) when is_list(values) do
    Enum.map(values, &to_string/1)
  end

  defp extract_multi_value(_), do: []

  defp connect do
    Logger.debug("Connecting to LDAP at #{@ldap_host}:#{@ldap_port}")
    {:ok, :mock_ldap_conn}
  end

  defp search(_conn, _filter) do
    {:ok, []}
  end

  def user_in_group?(%{groups: groups}, group_dn) do
    Enum.any?(groups, &String.contains?(&1, group_dn))
  end

  def admin?(%{groups: groups}) do
    Enum.any?(groups, &String.contains?(&1, "CN=Admins"))
  end

  def format_user(%{display_name: name, email: email, department: dept, title: title}) do
    "#{name} <#{email}> — #{title} in #{dept}"
  end

  def format_user(_), do: "Unknown User"
end
```
