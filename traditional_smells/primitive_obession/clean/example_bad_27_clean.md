```elixir
defmodule Notifications.EmailDispatcher do
  @moduledoc """
  Handles outbound transactional and bulk email delivery.
  Manages suppression lists, bounce tracking, and SMTP dispatch
  via the configured mail adapter.
  """

  require Logger

  alias Notifications.Repo
  alias Notifications.Schema.{EmailLog, SuppressionEntry}
  alias Notifications.MailAdapter

  @max_bulk_recipients 500
  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/


  @spec send_transactional(String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def send_transactional(to_address, template_name, variables)
      when is_binary(to_address) and is_binary(template_name) do
    with :ok <- validate_recipient(to_address),
         false <- suppressed?(to_address),
         {:ok, rendered} <- render_template(template_name, variables),
         {:ok, message_id} <- MailAdapter.deliver(%{
           to: to_address,
           subject: rendered.subject,
           html_body: rendered.html,
           text_body: rendered.text
         }) do
      domain = extract_domain(to_address)

      log_attrs = %{
        recipient: to_address,
        recipient_domain: domain,
        template: template_name,
        message_id: message_id,
        status: :delivered,
        sent_at: DateTime.utc_now()
      }

      %EmailLog{} |> EmailLog.changeset(log_attrs) |> Repo.insert!()
      Logger.info("Transactional email sent to=#{sanitize_for_log(to_address)} template=#{template_name}")
      {:ok, message_id}
    else
      true -> {:error, :recipient_suppressed}
      error -> error
    end
  end

  @spec send_bulk(list(String.t()), map()) ::
          {:ok, map()} | {:error, term()}
  def send_bulk(recipients, campaign) when is_list(recipients) do
    if length(recipients) > @max_bulk_recipients do
      {:error, {:too_many_recipients, length(recipients)}}
    else
      valid_recipients =
        recipients
        |> Enum.filter(&Regex.match?(@email_regex, &1))
        |> Enum.reject(&suppressed?/1)

      results =
        Enum.map(valid_recipients, fn address ->
          domain = extract_domain(address)
          {address, MailAdapter.deliver(%{to: address, subject: campaign.subject, html_body: campaign.body, domain_hint: domain})}
        end)

      delivered = Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end)
      failed = length(results) - delivered

      Logger.info("Bulk send complete: delivered=#{delivered} failed=#{failed}")
      {:ok, %{delivered: delivered, failed: failed, total: length(valid_recipients)}}
    end
  end

  @spec add_to_suppression_list(String.t()) :: :ok | {:error, term()}
  def add_to_suppression_list(email_address) when is_binary(email_address) do
    with :ok <- validate_recipient(email_address) do
      domain = extract_domain(email_address)
      local = extract_local(email_address)

      attrs = %{
        email: String.downcase(email_address),
        local_part: local,
        domain: domain,
        suppressed_at: DateTime.utc_now()
      }

      case %SuppressionEntry{} |> SuppressionEntry.changeset(attrs) |> Repo.insert(on_conflict: :nothing) do
        {:ok, _} -> :ok
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @spec validate_recipient(String.t()) :: :ok | {:error, term()}
  def validate_recipient(address) when is_binary(address) do
    cond do
      not Regex.match?(@email_regex, address) ->
        {:error, {:invalid_email_format, address}}

      String.length(extract_domain(address)) < 4 ->
        {:error, {:invalid_domain, address}}

      String.contains?(address, "..") ->
        {:error, {:invalid_email_consecutive_dots, address}}

      true ->
        :ok
    end
  end


  ## Private helpers

  defp extract_domain(address) when is_binary(address) do
    address
    |> String.split("@")
    |> List.last()
    |> String.downcase()
  end

  defp extract_local(address) when is_binary(address) do
    address
    |> String.split("@")
    |> List.first()
    |> String.downcase()
  end

  defp suppressed?(address) do
    normalized = String.downcase(address)
    Repo.exists?(SuppressionEntry, email: normalized)
  end

  defp sanitize_for_log(address) do
    [local | _] = String.split(address, "@")
    masked_local = String.slice(local, 0, 2) <> "***"
    "#{masked_local}@#{extract_domain(address)}"
  end

  defp render_template(name, variables) do
    case MailAdapter.render(name, variables) do
      {:ok, rendered} -> {:ok, rendered}
      {:error, reason} -> {:error, {:template_render_failed, reason}}
    end
  end
end
```