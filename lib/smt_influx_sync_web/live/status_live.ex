defmodule SmtInfluxSyncWeb.StatusLive do
  use SmtInfluxSyncWeb, :live_view
  alias SmtInfluxSync.Config
  alias SmtInfluxSync.ConfigManager

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(5000, self(), :tick)

    {:ok, assign_data(socket)}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("save_config", params, socket) do
    # Filter out empty strings or handle conversions as needed
    updates =
      params
      |> Map.take([
        "smt_username", "smt_password", "smt_esiid", "smt_meter_number",
        "influx_url", "influx_token", "influx_org", "influx_bucket",
        "ynab_access_token", "ynab_budget_id", "ynab_category_id", "kwh_rate"
      ])
      |> Map.new(fn {k, v} -> {String.to_atom(k), parse_value(k, v)} end)

    ConfigManager.update_config(updates)
    {:noreply, socket |> put_flash(:info, "Configuration updated!") |> assign_data()}
  end

  defp parse_value("kwh_rate", v), do: String.to_float(v)
  defp parse_value(_, v), do: v

  defp assign_data(socket) do
    assign(socket,
      sync_status: fetch_sync_status(),
      influx_status: SmtInfluxSync.InfluxWriter.get_status(),
      recent_logs: SmtInfluxSync.SyncMetadata.list_recent_logs(10),
      config: %{
        smt_username: Config.smt_username(),
        smt_password: Config.smt_password(),
        smt_esiid: Config.smt_esiid(),
        smt_meter_number: Config.smt_meter_number(),
        influx_url: Config.influx_url(),
        influx_token: Config.influx_token(),
        influx_org: Config.influx_org(),
        influx_bucket: Config.influx_bucket(),
        ynab_access_token: Config.ynab_access_token(),
        ynab_budget_id: Config.ynab_budget_id(),
        ynab_category_id: Config.ynab_category_id(),
        kwh_rate: Config.kwh_rate()
      }
    )
  end

  defp fetch_sync_status do
    ~w(daily interval monthly odr ynab)
    |> Enum.map(fn source ->
      path = Config.last_sync_path(source)
      last_sync = if File.exists?(path), do: File.read!(path) |> String.trim(), else: "Never"
      {source, last_sync}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <h1 class="text-3xl font-bold mb-8 text-slate-800">SMT Influx Sync Status</h1>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-12">
        <div class="bg-white p-6 rounded-xl shadow-sm border border-slate-200">
          <h2 class="text-xl font-semibold mb-4 text-slate-700">Sync Status</h2>
          <dl class="space-y-3">
            <%= for {source, last_sync} <- @sync_status do %>
              <div class="flex justify-between border-b border-slate-100 pb-2">
                <dt class="text-slate-500 capitalize"><%= source %></dt>
                <dd class="font-medium text-slate-900"><%= last_sync %></dd>
              </div>
            <% end %>
          </dl>
        </div>

        <div class="bg-white p-6 rounded-xl shadow-sm border border-slate-200">
          <h2 class="text-xl font-semibold mb-4 text-slate-700">InfluxDB Writer</h2>
          <dl class="space-y-3">
            <div class="flex justify-between border-b border-slate-100 pb-2">
              <dt class="text-slate-500">Health</dt>
              <dd class="font-medium">
                <%= if @influx_status.healthy do %>
                  <span class="text-green-600">Healthy</span>
                <% else %>
                  <span class="text-red-600">Unhealthy</span>
                <% end %>
              </dd>
            </div>
            <div class="flex justify-between border-b border-slate-100 pb-2">
              <dt class="text-slate-500">Buffered Messages</dt>
              <dd class="font-medium text-slate-900"><%= @influx_status.pending_count %></dd>
            </div>
            <div class="flex justify-between border-b border-slate-100 pb-2">
              <dt class="text-slate-500">Last Write</dt>
              <dd class="font-medium text-slate-900">
                <%= if @influx_status.last_write_at do %>
                  <%= Calendar.strftime(@influx_status.last_write_at, "%H:%M:%S") %>
                  (<%= case @influx_status.last_write_status do
                    :ok -> "Success"
                    {:error, reason} -> "Error: #{inspect(reason)}"
                    other -> inspect(other)
                  end %>)
                <% else %>
                  Never
                <% end %>
              </dd>
            </div>
          </dl>
          <div class="mt-6">
            <a href="/dashboard" class="block w-full text-center px-4 py-2 bg-slate-100 hover:bg-slate-200 text-slate-700 rounded-lg transition">
              View Phoenix Dashboard
            </a>
          </div>
        </div>
      </div>

      <div class="bg-white p-8 rounded-xl shadow-sm border border-slate-200 mb-12">
        <h2 class="text-2xl font-semibold mb-6 text-slate-700">Sync History</h2>
        <div class="overflow-x-auto">
          <table class="w-full text-left">
            <thead>
              <tr class="text-slate-500 border-b border-slate-100">
                <th class="pb-3 font-medium">Source</th>
                <th class="pb-3 font-medium">Status</th>
                <th class="pb-3 font-medium">Time</th>
                <th class="pb-3 font-medium">Message</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-slate-50">
              <%= for log <- @recent_logs do %>
                <tr>
                  <td class="py-3 capitalize font-medium text-slate-700"><%= log.source %></td>
                  <td class="py-3">
                    <span class={[
                      "px-2 py-1 rounded-full text-xs font-semibold",
                      log.status == "success" && "bg-green-100 text-green-700",
                      log.status == "fail" && "bg-red-100 text-red-700",
                      log.status == "start" && "bg-blue-100 text-blue-700"
                    ]}>
                      <%= log.status %>
                    </span>
                  </td>
                  <td class="py-3 text-slate-500 text-sm">
                    <%= Calendar.strftime(log.inserted_at, "%m/%d %H:%M:%S") %>
                  </td>
                  <td class="py-3 text-slate-600 text-sm truncate max-w-xs">
                    <%= log.message %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>

      <div class="bg-white p-8 rounded-xl shadow-sm border border-slate-200">
        <h2 class="text-2xl font-semibold mb-6 text-slate-700">Configuration</h2>
        <form phx-submit="save_config" class="space-y-6">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">SMT Username</label>
              <input type="text" name="smt_username" value={@config.smt_username} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">SMT Password</label>
              <input type="password" name="smt_password" value={@config.smt_password} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">ESIID</label>
              <input type="text" name="smt_esiid" value={@config.smt_esiid} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">Meter Number</label>
              <input type="text" name="smt_meter_number" value={@config.smt_meter_number} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
          </div>

          <hr class="border-slate-100" />

          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">InfluxDB URL</label>
              <input type="text" name="influx_url" value={@config.influx_url} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">InfluxDB Org</label>
              <input type="text" name="influx_org" value={@config.influx_org} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">InfluxDB Bucket</label>
              <input type="text" name="influx_bucket" value={@config.influx_bucket} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">InfluxDB Token</label>
              <input type="password" name="influx_token" value={@config.influx_token} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
          </div>

          <hr class="border-slate-100" />

          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">YNAB Access Token</label>
              <input type="password" name="ynab_access_token" value={@config.ynab_access_token} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">YNAB Budget ID</label>
              <input type="text" name="ynab_budget_id" value={@config.ynab_budget_id} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">YNAB Category ID</label>
              <input type="text" name="ynab_category_id" value={@config.ynab_category_id} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">kWh Rate ($)</label>
              <input type="text" name="kwh_rate" value={@config.kwh_rate} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
          </div>

          <div class="pt-4">
            <button type="submit" class="w-full md:w-auto px-8 py-3 bg-indigo-600 hover:bg-indigo-700 text-white font-semibold rounded-lg shadow-sm transition">
              Save Configuration
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
