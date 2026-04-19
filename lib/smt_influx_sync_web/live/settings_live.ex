defmodule SmtInfluxSyncWeb.SettingsLive do
  use SmtInfluxSyncWeb, :live_view
  alias SmtInfluxSync.Config
  alias SmtInfluxSync.ConfigManager

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_data(socket) |> assign(show_clear_confirm: false)}
  end

  @impl true
  def handle_event("add_tier", _params, socket) do
    tiers = socket.assigns.config.kwh_tiers ++ [%{limit: 0, rate: 0.0}]
    config = put_in(socket.assigns.config.kwh_tiers, tiers)
    {:noreply, assign(socket, config: config)}
  end

  @impl true
  def handle_event("show_clear_confirm", _params, socket) do
    {:noreply, assign(socket, show_clear_confirm: true)}
  end

  @impl true
  def handle_event("cancel_clear", _params, socket) do
    {:noreply, assign(socket, show_clear_confirm: false)}
  end

  @impl true
  def handle_event("confirm_clear_data", _params, socket) do
    SmtInfluxSync.SyncMetadata.clear_all_sync_data()
    {:noreply, 
     socket 
     |> put_flash(:info, "All sync metadata cleared! System will start a fresh sync.")
     |> assign(show_clear_confirm: false)
     |> assign_data()}
  end

  @impl true
  def handle_event("remove_tier", %{"index" => index}, socket) do
    idx = String.to_integer(index)
    tiers = List.delete_at(socket.assigns.config.kwh_tiers, idx)
    config = put_in(socket.assigns.config.kwh_tiers, tiers)
    {:noreply, assign(socket, config: config)}
  end

  @impl true
  def handle_event("toggle_meter", %{"id" => id}, socket) do
    SmtInfluxSync.Meter.toggle_active(id)
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("update_meter_label", %{"id" => id, "label" => label}, socket) do
    SmtInfluxSync.Meter.update_label(id, label)
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("add_meter", %{"esiid" => esiid, "meter_number" => meter_number}, socket) do
    case SmtInfluxSync.Meter.upsert(esiid, meter_number) do
      {:ok, _meter} ->
        {:noreply, socket |> put_flash(:info, "Meter added successfully!") |> assign_data()}
      {:error, changeset} ->
        # Simple error handling for now
        errors = Enum.map(changeset.errors, fn {k, {msg, _}} -> "#{k} #{msg}" end) |> Enum.join(", ")
        {:noreply, socket |> put_flash(:error, "Failed to add meter: #{errors}")}
    end
  end

  @impl true
  def handle_event("save_config", params, socket) do
    # Extract tiers from params
    # Phoenix forms with multiple inputs of same name can be tricky if not using schemas,
    # but we can use nested naming or indexed names.
    # We'll use indexed names: tiers[0][limit], tiers[0][rate]
    
    tiers = 
      params
      |> Map.get("tiers", %{})
      |> Map.values()
      |> Enum.map(fn t -> 
        %{limit: parse_float_safe(t["limit"]), rate: parse_float_safe(t["rate"])}
      end)

    updates =
      params
      |> Map.take([
        "smt_username", "smt_password", "smt_esiid",
        "influx_url", "influx_token", "influx_org", "influx_bucket",
        "ynab_access_token", "ynab_budget_id", "ynab_category_id", "kwh_rate",
        "odr_sync_time", "interval_sync_time", "daily_sync_time", "monthly_sync_time", "ynab_sync_time",
        "discord_webhook_url", "slack_webhook_url", "healthchecks_ping_url"
      ])
      |> Map.new(fn {k, v} -> {String.to_atom(k), parse_value(k, v)} end)
      |> Map.put(:kwh_tiers, tiers)

    ConfigManager.update_config(updates)
    {:noreply, socket |> put_flash(:info, "Configuration updated!") |> assign_data()}
  end

  defp parse_value("kwh_rate", v), do: parse_float_safe(v)
  defp parse_value(k, v) when k in ["discord_webhook_url", "slack_webhook_url", "healthchecks_ping_url"] do
    if String.trim(v) == "", do: nil, else: String.trim(v)
  end
  defp parse_value(_, v), do: v

  defp parse_float_safe(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 
        case Integer.parse(v) do
          {i, _} -> i / 1.0
          :error -> 0.0
        end
    end
  end

  defp assign_data(socket) do
    tiers = 
      case Config.kwh_tiers() do
        t when is_list(t) -> 
          Enum.map(t, fn
            %{"limit" => l, "rate" => r} -> %{limit: l, rate: r}
            m when is_map(m) -> m
          end)
        t when is_binary(t) -> 
          # Migrating legacy string to list if needed
          if String.trim(t) == "" do
            []
          else
            try do
              String.split(t, ",")
              |> Enum.flat_map(fn part ->
                if String.contains?(part, ":") do
                  [limit, rate] = String.split(part, ":")
                  [%{limit: parse_float_safe(limit), rate: parse_float_safe(rate)}]
                else
                  []
                end
              end)
            rescue
              _ -> []
            end
          end
        _ -> []
      end

    assign(socket,
      meters: SmtInfluxSync.Meter.list_all(),
      config: %{
        smt_username: Config.smt_username(),
        smt_password: Config.smt_password(),
        smt_esiid: Config.smt_esiid(),
        influx_url: Config.influx_url(),
        influx_token: Config.influx_token(),
        influx_org: Config.influx_org(),
        influx_bucket: Config.influx_bucket(),
        ynab_access_token: Config.ynab_access_token(),
        ynab_budget_id: Config.ynab_budget_id(),
        ynab_category_id: Config.ynab_category_id(),
        kwh_rate: Config.kwh_rate(),
        kwh_tiers: tiers,
        odr_sync_time: Config.odr_sync_time(),
        interval_sync_time: Config.interval_sync_time(),
        daily_sync_time: Config.daily_sync_time(),
        monthly_sync_time: Config.monthly_sync_time(),
        ynab_sync_time: Config.ynab_sync_time(),
        discord_webhook_url: Config.discord_webhook_url() || "",
        slack_webhook_url: Config.slack_webhook_url() || "",
        healthchecks_ping_url: Config.healthchecks_ping_url() || ""
      }
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-6">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <h1 class="text-3xl font-bold mb-8 text-slate-800">Settings</h1>

      <!-- Meter Management -->
      <div class="bg-white p-8 rounded-xl shadow-sm border border-slate-200 mb-8">
        <h2 class="text-xl font-semibold mb-6 text-slate-700 flex items-center gap-2">
          <svg class="w-5 h-5 text-indigo-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 3v2m6-2v2M9 19v2m6-2v2M5 9H3m2 6H3m18-6h-2m2 6h-2M7 19h10a2 2 0 002-2V7a2 2 0 00-2-2H7a2 2 0 00-2 2v10a2 2 0 002 2zM9 9h6v6H9V9z" />
          </svg>
          Meter Management
        </h2>
        <div class="overflow-x-auto">
          <table class="w-full text-left">
            <thead>
              <tr class="text-slate-500 border-b border-slate-100">
                <th class="pb-3 font-medium">ESIID</th>
                <th class="pb-3 font-medium">Meter Number</th>
                <th class="pb-3 font-medium">Label (Name)</th>
                <th class="pb-3 font-medium">Status</th>
                <th class="pb-3 font-medium text-right">Action</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-slate-50">
              <%= for meter <- @meters do %>
                <tr>
                  <td class="py-4 font-mono text-xs text-slate-700"><%= meter.esiid %></td>
                  <td class="py-4 text-sm text-slate-600"><%= meter.meter_number %></td>
                  <td class="py-4">
                    <input
                      type="text"
                      value={meter.label}
                      placeholder="e.g. Main House"
                      phx-blur="update_meter_label"
                      phx-value-id={meter.id}
                      name="meter_label"
                      class="text-sm border-slate-200 rounded-md focus:ring-indigo-500 focus:border-indigo-500 w-full max-w-xs"
                    />
                  </td>
                  <td class="py-4">
                    <span class={[
                      "px-2 py-1 rounded-full text-xs font-semibold",
                      meter.is_active && "bg-green-100 text-green-700",
                      !meter.is_active && "bg-slate-100 text-slate-700"
                    ]}>
                      <%= if meter.is_active, do: "Active", else: "Inactive" %>
                    </span>
                  </td>
                  <td class="py-4 text-right">
                    <button
                      type="button"
                      phx-click="toggle_meter"
                      phx-value-id={meter.id}
                      class={[
                        "text-xs px-3 py-1 font-semibold rounded transition",
                        meter.is_active && "bg-red-50 hover:bg-red-100 text-red-600",
                        !meter.is_active && "bg-green-50 hover:bg-green-100 text-green-600"
                      ]}
                    >
                      <%= if meter.is_active, do: "Deactivate", else: "Activate" %>
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        
        <div class="mt-8 pt-6 border-t border-slate-100">
          <h3 class="text-sm font-semibold text-slate-900 mb-4 uppercase tracking-wider">Manually Add Meter</h3>
          <form phx-submit="add_meter" class="flex flex-wrap items-end gap-4">
            <div class="flex-1 min-w-[200px]">
              <label class="block text-[10px] font-bold text-slate-500 uppercase mb-1">ESIID</label>
              <input type="text" name="esiid" required class="w-full text-sm rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" placeholder="e.g. 10443720000000000" />
            </div>
            <div class="flex-1 min-w-[200px]">
              <label class="block text-[10px] font-bold text-slate-500 uppercase mb-1">Meter Number</label>
              <input type="text" name="meter_number" required class="w-full text-sm rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" placeholder="e.g. 123456789" />
            </div>
            <button type="submit" class="px-4 py-2 bg-slate-800 hover:bg-slate-900 text-white text-sm font-semibold rounded-md transition shadow-sm">
              Add Meter
            </button>
          </form>
        </div>

        <p class="mt-4 text-xs text-slate-400 italic">
          Labels help you identify meters. Changes are saved automatically when you click away.
        </p>
      </div>

      <form phx-submit="save_config" class="space-y-8">
        <!-- Account & Connection -->
        <div class="bg-white p-8 rounded-xl shadow-sm border border-slate-200">
          <h2 class="text-xl font-semibold mb-6 text-slate-700 flex items-center gap-2">
            <svg class="w-5 h-5 text-indigo-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 16l-4-4m0 0l4-4m-4 4h12m-5 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h7a3 3 0 013 3v1" />
            </svg>
            SMT & InfluxDB Connection
          </h2>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div class="md:col-span-2">
              <label class="block text-sm font-medium text-slate-700 mb-1">SMT Username</label>
              <input type="text" name="smt_username" value={@config.smt_username} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div class="md:col-span-2">
              <label class="block text-sm font-medium text-slate-700 mb-1">SMT Password</label>
              <input type="password" name="smt_password" value={@config.smt_password} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div class="md:col-span-2">
              <label class="block text-sm font-medium text-slate-700 mb-1">ESIID Filter (use * for all)</label>
              <input type="text" name="smt_esiid" value={@config.smt_esiid} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            
            <div class="md:col-span-2 mt-4 pt-4 border-t border-slate-100"></div>

            <div class="md:col-span-2">
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
            <div class="md:col-span-2">
              <label class="block text-sm font-medium text-slate-700 mb-1">InfluxDB Token</label>
              <input type="password" name="influx_token" value={@config.influx_token} class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
          </div>
        </div>

        <!-- Electricity Pricing -->
        <div class="bg-white p-8 rounded-xl shadow-sm border border-slate-200">
          <h2 class="text-xl font-semibold mb-6 text-slate-700 flex items-center gap-2">
            <svg class="w-5 h-5 text-indigo-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8c-1.657 0-3 .895-3 2s1.343 2 3 2 3 .895 3 2-1.343 2-3 2m0-8c1.11 0 2.08.402 2.599 1M12 8V7m0 1v8m0 0v1m0-1c-1.11 0-2.08-.402-2.599-1M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            Electricity Pricing & YNAB
          </h2>
          
          <div class="space-y-6">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
              <div class="md:col-span-2">
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
            </div>

            <div class="pt-6 border-t border-slate-100">
              <h3 class="text-sm font-semibold text-slate-900 mb-4 uppercase tracking-wider">Rate Tiers</h3>
              
              <div class="space-y-3 mb-4">
                <%= for {tier, index} <- Enum.with_index(@config.kwh_tiers) do %>
                  <div class="flex items-end gap-4 bg-slate-50 p-3 rounded-lg border border-slate-100">
                    <div class="flex-1">
                      <label class="block text-[10px] font-bold text-slate-500 uppercase mb-1">Up to (kWh)</label>
                      <input type="number" step="any" name={"tiers[#{index}][limit]"} value={tier.limit} class="w-full text-sm rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
                    </div>
                    <div class="flex-1">
                      <label class="block text-[10px] font-bold text-slate-500 uppercase mb-1">Rate ($/kWh)</label>
                      <input type="number" step="0.0001" name={"tiers[#{index}][rate]"} value={tier.rate} class="w-full text-sm rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
                    </div>
                    <button type="button" phx-click="remove_tier" phx-value-index={index} class="p-2 text-slate-400 hover:text-red-600 transition">
                      <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                      </svg>
                    </button>
                  </div>
                <% end %>
              </div>

              <button type="button" phx-click="add_tier" class="flex items-center gap-2 text-sm text-indigo-600 font-semibold hover:text-indigo-700 transition">
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
                </svg>
                Add Pricing Tier
              </button>

              <div class="mt-6 p-4 bg-indigo-50 rounded-lg border border-indigo-100">
                <label class="block text-sm font-semibold text-indigo-900 mb-1">Base Rate ($/kWh)</label>
                <p class="text-xs text-indigo-700 mb-3">This rate is used for all usage above your tiers, or for everything if no tiers are defined.</p>
                <input type="number" step="0.0001" name="kwh_rate" value={@config.kwh_rate} class="w-full max-w-xs text-sm rounded-md border-indigo-200 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
              </div>
            </div>
          </div>
        </div>

        <!-- Sync Schedule -->
        <div class="bg-white p-8 rounded-xl shadow-sm border border-slate-200">
          <h2 class="text-xl font-semibold mb-6 text-slate-700 flex items-center gap-2">
            <svg class="w-5 h-5 text-indigo-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            Sync Schedule (HH:MM)
          </h2>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">ODR Sync Time</label>
              <input type="text" name="odr_sync_time" value={@config.odr_sync_time} placeholder="02:00" class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">Interval Sync Time</label>
              <input type="text" name="interval_sync_time" value={@config.interval_sync_time} placeholder="02:30" class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">Daily Sync Time</label>
              <input type="text" name="daily_sync_time" value={@config.daily_sync_time} placeholder="02:45" class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">Monthly Sync Time</label>
              <input type="text" name="monthly_sync_time" value={@config.monthly_sync_time} placeholder="03:15" class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">YNAB Sync Time</label>
              <input type="text" name="ynab_sync_time" value={@config.ynab_sync_time} placeholder="03:00" class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
            </div>
          </div>
        </div>

        <!-- Notifications -->
        <div class="bg-white p-8 rounded-xl shadow-sm border border-slate-200">
          <h2 class="text-xl font-semibold mb-6 text-slate-700 flex items-center gap-2">
            <svg class="w-5 h-5 text-indigo-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9" />
            </svg>
            Notifications
          </h2>
          <p class="text-sm text-slate-500 mb-6">Configure webhooks to receive alerts when data goes stale. Leave blank to disable.</p>
          <div class="grid grid-cols-1 gap-6">
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">Discord Webhook URL</label>
              <input type="text" name="discord_webhook_url" value={@config.discord_webhook_url}
                placeholder="https://discord.com/api/webhooks/..."
                class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 font-mono text-sm" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">Slack Webhook URL</label>
              <input type="text" name="slack_webhook_url" value={@config.slack_webhook_url}
                placeholder="https://hooks.slack.com/services/..."
                class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 font-mono text-sm" />
            </div>
            <div>
              <label class="block text-sm font-medium text-slate-700 mb-1">Healthchecks.io Ping URL</label>
              <input type="text" name="healthchecks_ping_url" value={@config.healthchecks_ping_url}
                placeholder="https://hc-ping.com/..."
                class="w-full rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500 font-mono text-sm" />
            </div>
          </div>
        </div>

        <div class="sticky bottom-6 bg-white/80 backdrop-blur-sm p-4 rounded-xl shadow-lg border border-slate-200 flex justify-between items-center">
          <div>
            <button type="button" phx-click="show_clear_confirm" class="px-4 py-2 bg-red-50 hover:bg-red-100 text-red-600 text-sm font-semibold rounded-lg transition border border-red-100">
              Clear All Sync Data
            </button>
          </div>
          <div class="flex gap-4">
            <a href="/" class="px-6 py-3 text-slate-600 font-semibold rounded-lg hover:bg-slate-100 transition">Cancel</a>
            <button type="submit" class="px-10 py-3 bg-indigo-600 hover:bg-indigo-700 text-white font-bold rounded-lg shadow-md transition transform active:scale-95">
              Save All Settings
            </button>
          </div>
        </div>
      </form>

      <!-- Confirmation Modal -->
      <%= if @show_clear_confirm do %>
        <div class="fixed inset-0 bg-slate-900/50 backdrop-blur-sm z-[100] flex items-center justify-center p-4">
          <div class="bg-white rounded-2xl shadow-2xl border border-slate-200 max-w-md w-full p-8">
            <div class="w-16 h-16 bg-red-100 rounded-full flex items-center justify-center mb-6 mx-auto">
              <svg class="w-8 h-8 text-red-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
              </svg>
            </div>
            <h3 class="text-xl font-bold text-center text-slate-900 mb-2">Clear All Sync Data?</h3>
            <p class="text-slate-500 text-center mb-8">
              This will delete all sync logs, reset meter tracking, and clear pending writes. 
              The system will re-sync everything from scratch on the next scheduled run. 
              This cannot be undone.
            </p>
            <div class="flex flex-col gap-3">
              <button 
                phx-click="confirm_clear_data" 
                class="w-full py-3 bg-red-600 hover:bg-red-700 text-white font-bold rounded-xl shadow-lg transition"
              >
                Yes, Clear Everything
              </button>
              <button 
                phx-click="cancel_clear" 
                class="w-full py-3 bg-slate-100 hover:bg-slate-200 text-slate-700 font-semibold rounded-xl transition"
              >
                Cancel
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
