defmodule SmtInfluxSyncWeb.CoreComponents do
  use Phoenix.Component

  def flash(assigns) do
    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      id={"flash-#{@kind}"}
      class={[
        "fixed top-4 right-4 z-50 rounded-lg p-4 shadow-md",
        @kind == :info && "bg-blue-100 text-blue-800 border border-blue-200",
        @kind == :error && "bg-red-100 text-red-800 border border-red-200"
      ]}
    >
      <%= msg %>
    </div>
    """
  end
end
