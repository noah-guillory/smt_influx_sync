defmodule SmtInfluxSync.Notifier do
  @moduledoc """
  Sends notifications via Discord or Slack webhooks.
  """
  require Logger
  alias SmtInfluxSync.Config

  def notify(message) do
    send_discord(message)
    send_slack(message)
  end

  defp send_discord(message) do
    if url = Config.discord_webhook_url() do
      Req.post(url, json: %{content: message}, retry: false)
      |> handle_response("Discord")
    end
  end

  defp send_slack(message) do
    if url = Config.slack_webhook_url() do
      Req.post(url, json: %{text: message}, retry: false)
      |> handle_response("Slack")
    end
  end

  defp handle_response(result, service) do
    case result do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.debug("[notifier] #{service} notification sent")
      {:ok, %{status: status, body: body}} ->
        Logger.warning("[notifier] #{service} failed with HTTP #{status}: #{inspect(body)}")
      {:error, reason} ->
        Logger.warning("[notifier] #{service} failed: #{inspect(reason)}")
    end
  end
end
