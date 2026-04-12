defmodule SmtInfluxSyncWeb.ErrorHTML do
  use SmtInfluxSyncWeb, :html

  # If you want to customize your error pages,
  # you can expose function clauses for specific HTTP errors:
  #
  # def render("404.html", _assigns) do
  #   "Page Not Found"
  # end

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
