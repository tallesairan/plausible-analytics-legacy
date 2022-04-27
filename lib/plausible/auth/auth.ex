defmodule Plausible.Auth do
  use Plausible.Repo
  alias Plausible.Auth
  alias Plausible.Stats.Clickhouse, as: Stats

  def issue_email_verification(user) do
    Repo.update_all(from(c in "email_verification_codes", where: c.user_id == ^user.id),
      set: [user_id: nil]
    )

    code =
      Repo.one(
        from(c in "email_verification_codes", where: is_nil(c.user_id), select: c.code, limit: 1)
      )

    Repo.update_all(from(c in "email_verification_codes", where: c.code == ^code),
      set: [user_id: user.id, issued_at: Timex.now()]
    )

    code
  end

  defp is_expired?(activation_code_issued) do
    Timex.before?(activation_code_issued, Timex.shift(Timex.now(), hours: -4))
  end

  def verify_email(user, code) do
    found_code =
      Repo.one(
        from c in "email_verification_codes",
          where: c.user_id == ^user.id,
          where: c.code == ^code,
          select: %{code: c.code, issued: c.issued_at}
      )

    cond do
      is_nil(found_code) ->
        {:error, :incorrect}

      is_expired?(found_code[:issued]) ->
        {:error, :expired}

      true ->
        {:ok, _} =
          Ecto.Multi.new()
          |> Ecto.Multi.update(
            :user,
            Plausible.Auth.User.changeset(user, %{email_verified: true})
          )
          |> Ecto.Multi.update_all(
            :codes,
            from(c in "email_verification_codes", where: c.user_id == ^user.id),
            set: [user_id: nil]
          )
          |> Repo.transaction()

        :ok
    end
  end

  def create_user(name, email, pwd) do
    %Auth.User{}
    |> Auth.User.new(%{name: name, email: email, password: pwd, password_confirmation: pwd})
    |> Repo.insert()
  end

  def find_user_by(opts) do
    Repo.get_by(Auth.User, opts)
  end

  def user_completed_setup?(user) do
    domains =
      Repo.all(
        from u in Plausible.Auth.User,
          where: u.id == ^user.id,
          join: sm in Plausible.Site.Membership,
          on: sm.user_id == u.id,
          join: s in Plausible.Site,
          on: s.id == sm.site_id,
          select: s.domain
      )

    Stats.has_pageviews?(domains)
  end
end
