defmodule SmtInfluxSyncWeb.StatusLive do
  use SmtInfluxSyncWeb, :live_view
  alias SmtInfluxSync.Config

  @log_page_size 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(5000, self(), :tick)
      Phoenix.PubSub.subscribe(SmtInfluxSync.PubSub, "sync_events")
      Phoenix.PubSub.subscribe(SmtInfluxSync.PubSub, "system_logs")
    end

    {:ok,
     assign_data(socket)
     |> assign(
       active_tab: "history",
       log_level_filter: "all",
       system_logs_limit: @log_page_size,
       syncing_sources: MapSet.new()
     )
     |> load_system_logs()}
  end

  @impl true
  def handle_info({:log_event, _log}, socket) do
    # Re-fetch from DB so the tab reflects the persisted log even after refresh
    {:noreply, load_system_logs(socket)}
  end

  @impl true
  def handle_info({:sync_started, log}, socket) do
    syncing = MapSet.put(socket.assigns.syncing_sources, log.source)
    {:noreply, socket |> assign(syncing_sources: syncing) |> assign_data()}
  end

  @impl true
  def handle_info({event, log}, socket) when event in [:sync_completed, :sync_failed] do
    syncing = MapSet.delete(socket.assigns.syncing_sources, log.source)
    {:noreply, socket |> assign(syncing_sources: syncing) |> assign_data()}
  end

  @impl true
  def handle_info(:tick, socket) do
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("force_sync", %{"source" => source}, socket) do
    if Application.get_env(:smt_influx_sync, :oban_enabled, true) do
      worker =
        case source do
          "daily" -> SmtInfluxSync.Workers.Daily
          "interval" -> SmtInfluxSync.Workers.Interval
          "monthly" -> SmtInfluxSync.Workers.Monthly
          "odr" -> SmtInfluxSync.Workers.ODR
          "ynab" -> SmtInfluxSync.YnabSyncWorker
        end

      %{} |> worker.new() |> Oban.insert!()
      syncing = MapSet.put(socket.assigns.syncing_sources, source)
      {:noreply, socket |> assign(syncing_sources: syncing) |> put_flash(:info, "Sync triggered for #{source}!")}
    else
      {:noreply, socket |> put_flash(:error, "Oban is disabled, cannot trigger sync.")}
    end
  end

  @impl true
  def handle_event("historical_sync", %{"source" => source, "start_date" => start_date, "end_date" => end_date}, socket) do
    if Application.get_env(:smt_influx_sync, :oban_enabled, true) do
      worker =
        case source do
          "daily" -> SmtInfluxSync.Workers.Daily
          "interval" -> SmtInfluxSync.Workers.Interval
          "monthly" -> SmtInfluxSync.Workers.Monthly
        end

      %{"start_date" => start_date, "end_date" => end_date}
      |> worker.new()
      |> Oban.insert!()

      {:noreply, socket |> put_flash(:info, "Historical sync triggered for #{source} from #{start_date} to #{end_date}!")}
    else
      {:noreply, socket |> put_flash(:error, "Oban is disabled, cannot trigger sync.")}
    end
  end

  @impl true
  def handle_event("toggle_meter", %{"id" => id}, socket) do
    SmtInfluxSync.Meter.toggle_active(id)
    {:noreply, assign_data(socket)}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  @impl true
  def handle_event("set_log_filter", %{"level" => level}, socket) do
    {:noreply,
     socket
     |> assign(log_level_filter: level, system_logs_limit: @log_page_size)
     |> load_system_logs()}
  end

  @impl true
  def handle_event("load_more_logs", _params, socket) do
    new_limit = socket.assigns.system_logs_limit + @log_page_size
    {:noreply, socket |> assign(system_logs_limit: new_limit) |> load_system_logs()}
  end

  defp load_system_logs(socket) do
    logs = SmtInfluxSync.SystemLog.list_recent(
      socket.assigns.system_logs_limit,
      socket.assigns.log_level_filter
    )
    assign(socket, system_logs: logs)
  end

  defp format_ms(nil), do: "—"
  defp format_ms(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_ms(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp format_dt(nil), do: "Never"
  defp format_dt(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_dt()
  end
  defp format_dt(dt) do
    dt
    |> DateTime.shift_zone!(Config.timezone())
    |> Calendar.strftime("%m/%d %I:%M:%S %p")
  end

  defp format_time(nil), do: "Never"
  defp format_time(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_time()
  end
  defp format_time(dt) do
    dt
    |> DateTime.shift_zone!(Config.timezone())
    |> Calendar.strftime("%I:%M:%S %p")
  end

  defp assign_data(socket) do
    assign(socket,
      sync_status: fetch_sync_status(),
      influx_status: SmtInfluxSync.InfluxWriter.get_status(),
      recent_logs: SmtInfluxSync.SyncMetadata.list_recent_logs(10),
      duration_stats: fetch_duration_stats(),
      meters: SmtInfluxSync.Meter.list_all()
    )
  end

  defp fetch_duration_stats do
    ~w(daily interval monthly odr ynab)
    |> Enum.map(fn source ->
      {source, SmtInfluxSync.SyncMetadata.get_duration_stats(source)}
    end)
    |> Enum.into(%{})
  end

  defp fetch_sync_status do
    timezone = Config.timezone()
    now = DateTime.now!(timezone)

    active_meters = SmtInfluxSync.Meter.list_active()
    odr_count = Enum.sum(Enum.map(active_meters, &SmtInfluxSync.Workers.ODR.daily_count(&1.esiid)))
    odr_limit = max(1, length(active_meters)) * Config.odr_daily_limit()

    ~w(daily interval monthly odr ynab)
    |> Enum.map(fn source ->
      latest_log = SmtInfluxSync.SyncMetadata.get_latest_sync(source)

      last_sync =
        case latest_log do
          nil ->
            path = Config.last_sync_path(source)
            case File.read(path) do
              {:ok, contents} -> String.trim(contents)
              _ -> "Never"
            end
          log ->
            format_dt(log.completed_at)
        end

      latest_data_point =
        case SmtInfluxSync.SyncMetadata.get_latest_data_point(source) do
          nil -> "Never"
          dt -> format_dt(dt)
        end

      time_str =
        case source do
          "daily" -> Config.daily_sync_time()
          "interval" -> Config.interval_sync_time()
          "monthly" -> Config.monthly_sync_time()
          "odr" -> Config.odr_sync_time()
          "ynab" -> Config.ynab_sync_time()
        end

      {h, m} = Config.parse_time_string(time_str)
      ms_until = SmtInfluxSync.Workers.Helper.ms_until_next_time(h, m)
      next_sync_dt = DateTime.add(now, ms_until, :millisecond)
      next_sync = format_time(next_sync_dt)

      is_stale =
        case latest_log do
          %{completed_at: completed_at} ->
            stale_threshold =
              case source do
                "interval" -> 120 # 2 hours
                "daily" -> 48 * 60 # 48 hours
                "monthly" -> 48 * 60 # 48 hours
                "odr" -> 60 # 1 hour
                "ynab" -> 48 * 60 # 48 hours
                _ -> 60
              end
            DateTime.diff(DateTime.utc_now(), completed_at, :minute) > stale_threshold
          _ -> false
        end

      odr_gauge = if source == "odr", do: %{count: odr_count, limit: odr_limit}, else: nil
      %{source: source, last_sync: last_sync, next_sync: next_sync, latest_data_point: latest_data_point, is_stale: is_stale, odr_gauge: odr_gauge}
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
          <dl class="space-y-4">
            <%= for status <- @sync_status do %>
              <% is_syncing = MapSet.member?(@syncing_sources, status.source) %>
              <div class="flex justify-between items-center border-b border-slate-100 pb-3 last:border-0 last:pb-0">
                <div class="space-y-1">
                  <div class="flex items-center gap-2">
                    <dt class="text-slate-500 capitalize font-medium"><%= status.source %></dt>
                    <%= if is_syncing do %>
                      <span class="flex items-center gap-1 px-1.5 py-0.5 bg-indigo-100 text-indigo-600 text-[10px] font-bold rounded uppercase tracking-wider">
                        <svg class="w-2.5 h-2.5 animate-spin" fill="none" viewBox="0 0 24 24">
                          <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                          <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
                        </svg>
                        Syncing
                      </span>
                    <% end %>
                    <%= if status.is_stale and not is_syncing do %>
                      <span class="px-1.5 py-0.5 bg-red-100 text-red-600 text-[10px] font-bold rounded uppercase tracking-wider">Stale</span>
                    <% end %>
                  </div>
                  <dd class="text-xs text-slate-400">
                    Last: <span class="text-slate-900 font-medium"><%= status.last_sync %></span>
                  </dd>
                  <dd class="text-xs text-slate-400">
                    Data: <span class="text-green-600 font-medium"><%= status.latest_data_point %></span>
                  </dd>
                  <dd class="text-xs text-slate-400">
                    Next: <span class="text-indigo-600 font-medium"><%= status.next_sync %></span>
                  </dd>
                  <%= if g = status.odr_gauge do %>
                    <dd class="text-xs text-slate-400 pt-1">
                      <div class="flex items-center gap-2">
                        <span>Daily reads: <span class={[
                          "font-medium",
                          g.count >= g.limit && "text-red-600",
                          g.count >= div(g.limit, 2) && g.count < g.limit && "text-amber-600",
                          g.count < div(g.limit, 2) && "text-slate-700"
                        ]}><%= g.count %> / <%= g.limit %></span></span>
                      </div>
                      <div class="mt-1 w-full bg-slate-100 rounded-full h-1.5">
                        <div
                          class={[
                            "h-1.5 rounded-full transition-all",
                            g.count >= g.limit && "bg-red-500",
                            g.count >= div(g.limit, 2) && g.count < g.limit && "bg-amber-400",
                            g.count < div(g.limit, 2) && "bg-indigo-400"
                          ]}
                          style={"width: #{min(100, round(g.count / g.limit * 100))}%"}
                        ></div>
                      </div>
                    </dd>
                  <% end %>
                </div>
                <button
                  phx-click="force_sync"
                  phx-value-source={status.source}
                  disabled={is_syncing}
                  class={[
                    "text-xs px-3 py-1 font-semibold rounded transition",
                    is_syncing && "bg-slate-100 text-slate-400 cursor-not-allowed",
                    not is_syncing && "bg-indigo-50 hover:bg-indigo-100 text-indigo-600"
                  ]}
                >
                  Sync Now
                </button>
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
              <dd class="font-medium text-slate-900">
                <%= @influx_status.pending_count %>
                <span class={[
                  "ml-2 text-xs",
                  @influx_status.buffer_growth > 0 && "text-red-500",
                  @influx_status.buffer_growth < 0 && "text-green-500",
                  @influx_status.buffer_growth == 0 && "text-slate-400"
                ]}>
                  <%= if @influx_status.buffer_growth > 0, do: "+" %><%= @influx_status.buffer_growth %>/m
                </span>
              </dd>
            </div>
            <div class="flex justify-between border-b border-slate-100 pb-2">
              <dt class="text-slate-500">Last Write</dt>
              <dd class="font-medium text-slate-900">
                <%= if @influx_status.last_write_at do %>
                  <%= format_time(@influx_status.last_write_at) %>
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
            <div class="flex justify-between border-b border-slate-100 pb-2">
              <dt class="text-slate-500">Write Latency</dt>
              <dd class="font-medium text-slate-900 text-sm">
                <%= if @influx_status.write_latency do %>
                  avg <%= format_ms(@influx_status.write_latency.avg) %> &middot;
                  min <%= format_ms(@influx_status.write_latency.min) %> &middot;
                  max <%= format_ms(@influx_status.write_latency.max) %>
                  <span class="text-xs text-slate-400 ml-1">(<%= @influx_status.write_latency.samples %> samples)</span>
                <% else %>
                  <span class="text-slate-400">No data yet</span>
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
        <div class="flex border-b border-slate-100 mb-6">
          <button
            phx-click="set_tab"
            phx-value-tab="history"
            class={[
              "px-4 py-2 font-semibold transition border-b-2",
              @active_tab == "history" && "border-indigo-500 text-indigo-600",
              @active_tab != "history" && "border-transparent text-slate-400 hover:text-slate-600"
            ]}
          >
            Sync History
          </button>
          <button
            phx-click="set_tab"
            phx-value-tab="logs"
            class={[
              "px-4 py-2 font-semibold transition border-b-2",
              @active_tab == "logs" && "border-indigo-500 text-indigo-600",
              @active_tab != "logs" && "border-transparent text-slate-400 hover:text-slate-600"
            ]}
          >
            System Logs
          </button>
        </div>

        <%= if @active_tab == "history" do %>
          <%!-- Duration stats summary --%>
          <div class="grid grid-cols-2 md:grid-cols-5 gap-3 mb-6">
            <%= for source <- ~w(daily interval monthly odr ynab) do %>
              <div class="bg-slate-50 rounded-lg p-3 border border-slate-100">
                <div class="text-xs font-semibold text-slate-500 uppercase mb-1"><%= source %></div>
                <%= if stats = @duration_stats[source] do %>
                  <div class="text-xs text-slate-700">avg <span class="font-medium"><%= format_ms(stats.avg) %></span></div>
                  <div class="text-xs text-slate-500">p95 <%= format_ms(stats.p95) %> &middot; n=<%= stats.count %></div>
                <% else %>
                  <div class="text-xs text-slate-400 italic">No data</div>
                <% end %>
              </div>
            <% end %>
          </div>
          <div class="overflow-x-auto">
            <table class="w-full text-left">
              <thead>
                <tr class="text-slate-500 border-b border-slate-100">
                  <th class="pb-3 font-medium">Source</th>
                  <th class="pb-3 font-medium">Status</th>
                  <th class="pb-3 font-medium">Time</th>
                  <th class="pb-3 font-medium">Duration</th>
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
                      <%= format_dt(log.inserted_at) %>
                    </td>
                    <td class="py-3 text-slate-500 text-sm font-mono">
                      <%= format_ms(log.elapsed_ms) %>
                    </td>
                    <td class="py-3 text-slate-600 text-sm truncate max-w-xs">
                      <%= log.message %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% else %>
          <%!-- Level filter buttons --%>
          <div class="flex gap-2 mb-4">
            <%= for level <- ~w(all info warning error debug) do %>
              <button
                phx-click="set_log_filter"
                phx-value-level={level}
                class={[
                  "px-3 py-1 rounded-full text-xs font-semibold border transition",
                  @log_level_filter == level && "bg-indigo-600 text-white border-indigo-600",
                  @log_level_filter != level && "bg-white text-slate-500 border-slate-200 hover:border-indigo-300"
                ]}
              >
                <%= String.capitalize(level) %>
              </button>
            <% end %>
          </div>
          <div class="bg-slate-900 rounded-lg p-4 font-mono text-xs overflow-y-auto max-h-96 space-y-1">
            <%= for log <- @system_logs do %>
              <div class="flex gap-3">
                <span class="text-slate-500 shrink-0"><%= Calendar.strftime(log.inserted_at, "%H:%M:%S") %></span>
                <span class={[
                  "font-bold uppercase w-12 shrink-0",
                  log.level == "info" && "text-blue-400",
                  log.level == "warning" && "text-yellow-400",
                  log.level == "error" && "text-red-400",
                  log.level == "debug" && "text-slate-400"
                ]}><%= log.level %></span>
                <%= if log.source do %>
                  <span class="text-slate-500 shrink-0">[<%= log.source %>]</span>
                <% end %>
                <span class="text-slate-300 break-all"><%= log.message %></span>
              </div>
            <% end %>
            <%= if @system_logs == [] do %>
              <div class="text-slate-500 italic">No logs found.</div>
            <% end %>
          </div>
          <%= if length(@system_logs) >= @system_logs_limit do %>
            <div class="mt-3 text-center">
              <button
                phx-click="load_more_logs"
                class="text-sm px-4 py-2 bg-slate-100 hover:bg-slate-200 text-slate-600 rounded transition"
              >
                Load More
              </button>
            </div>
          <% end %>
        <% end %>
      </div>

      <div class="bg-white p-8 rounded-xl shadow-sm border border-slate-200 mb-12">
        <h2 class="text-2xl font-semibold mb-6 text-slate-700">Gap Filler (Historical Sync)</h2>
        <p class="text-slate-500 mb-6 text-sm">
          Trigger a manual sync for a specific date range. Useful for filling in missing data if the service was down.
        </p>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
          <%= for source <- ~w(interval daily monthly) do %>
            <div class="p-4 bg-slate-50 rounded-lg border border-slate-100">
              <h3 class="font-semibold text-slate-700 capitalize mb-3"><%= source %> Sync</h3>
              <form phx-submit="historical_sync" class="space-y-3">
                <input type="hidden" name="source" value={source} />
                <div>
                  <label class="block text-xs font-medium text-slate-500 mb-1">Start Date</label>
                  <input type="date" name="start_date" required class="w-full text-sm rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
                </div>
                <div>
                  <label class="block text-xs font-medium text-slate-500 mb-1">End Date</label>
                  <input type="date" name="end_date" required class="w-full text-sm rounded-md border-slate-300 shadow-sm focus:border-indigo-500 focus:ring-indigo-500" />
                </div>
                <button type="submit" class="w-full py-2 bg-indigo-600 hover:bg-indigo-700 text-white text-xs font-semibold rounded transition shadow-sm">
                  Run Historical Sync
                </button>
              </form>
            </div>
          <% end %>
        </div>
      </div>

      <div class="bg-white p-8 rounded-xl shadow-sm border border-slate-200 mb-12">
        <h2 class="text-2xl font-semibold mb-6 text-slate-700">Meter Management</h2>
        <div class="overflow-x-auto">
          <table class="w-full text-left">
            <thead>
              <tr class="text-slate-500 border-b border-slate-100">
                <th class="pb-3 font-medium">Meter</th>
                <th class="pb-3 font-medium">ESIID</th>
                <th class="pb-3 font-medium">Latest Data</th>
                <th class="pb-3 font-medium">Status</th>
                <th class="pb-3 font-medium">Action</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-slate-50">
              <%= for meter <- @meters do %>
                <tr>
                  <td class="py-3">
                    <div class="font-medium text-slate-700"><%= meter.label || "Unnamed Meter" %></div>
                    <div class="text-xs text-slate-400 font-mono"><%= meter.meter_number %></div>
                  </td>
                  <td class="py-3 font-mono text-xs text-slate-600"><%= meter.esiid %></td>
                  <td class="py-3">
                    <div class="text-[10px] text-slate-400 uppercase">Interval</div>
                    <div class="text-xs text-slate-700 mb-1"><%= format_dt(meter.last_interval_at) %></div>
                    <div class="text-[10px] text-slate-400 uppercase">Daily</div>
                    <div class="text-xs text-slate-700"><%= format_dt(meter.last_daily_at) %></div>
                  </td>
                  <td class="py-3">
                    <span class={[
                      "px-2 py-1 rounded-full text-xs font-semibold",
                      meter.is_active && "bg-green-100 text-green-700",
                      !meter.is_active && "bg-slate-100 text-slate-700"
                    ]}>
                      <%= if meter.is_active, do: "Active", else: "Inactive" %>
                    </span>
                  </td>
                  <td class="py-3">
                    <button
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
        <p class="mt-4 text-xs text-slate-400 italic">
          Meters are automatically discovered during session setup based on your SMT ESIID configuration.
        </p>
      </div>
    </div>
    """
  end
end
