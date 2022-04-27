defmodule PlausibleWeb.CRMAuthPlug do
  import Plug.Conn
  use Plausible.Repo

  def init(options) do
    options
  end

  def call(conn, _opts) do
    case get_session(conn, :current_user_id) do
      nil ->
        conn |> send_resp(403, "Not allowed") |> halt

      id ->
        user = Repo.get_by(Plausible.Auth.User, id: id)

        if user && user.email in admin_emails() do
          assign(conn, :current_user, user)
        else
          conn |> send_resp(403, "Not allowed") |> halt
        end
    end
  end

  defp admin_emails(), do: Application.get_env(:plausible, :admin_emails)
end
