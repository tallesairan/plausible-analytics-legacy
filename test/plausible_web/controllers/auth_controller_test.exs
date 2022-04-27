defmodule PlausibleWeb.AuthControllerTest do
  use PlausibleWeb.ConnCase
  use Bamboo.Test
  use Plausible.Repo
  import Plausible.TestUtils

  describe "GET /register" do
    test "shows the register form", %{conn: conn} do
      conn = get(conn, "/register")

      assert html_response(conn, 200) =~ "Enter your details"
    end
  end

  describe "POST /register" do
    test "registering sends an activation link", %{conn: conn} do
      post(conn, "/register",
        user: %{
          name: "Jane Doe",
          email: "user@example.com",
          password: "very-secret",
          password_confirmation: "very-secret"
        }
      )

      assert_delivered_email_matches(%{to: [{_, user_email}], subject: subject})
      assert user_email == "user@example.com"
      assert subject =~ "is your Plausible email verification code"
    end

    test "creates user record", %{conn: conn} do
      post(conn, "/register",
        user: %{
          name: "Jane Doe",
          email: "user@example.com",
          password: "very-secret",
          password_confirmation: "very-secret"
        }
      )

      user = Repo.one(Plausible.Auth.User)
      assert user.name == "Jane Doe"
    end

    test "logs the user in", %{conn: conn} do
      conn =
        post(conn, "/register",
          user: %{
            name: "Jane Doe",
            email: "user@example.com",
            password: "very-secret",
            password_confirmation: "very-secret"
          }
        )

      assert get_session(conn, :current_user_id)
    end

    test "user is redirected to activation after registration", %{conn: conn} do
      conn =
        post(conn, "/register",
          user: %{
            name: "Jane Doe",
            email: "user@example.com",
            password: "very-secret",
            password_confirmation: "very-secret"
          }
        )

      assert redirected_to(conn) == "/activate"
    end
  end

  describe "GET /activate" do
    setup [:create_user, :log_in]

    test "if user does not have a code: prompts user to request activation code", %{conn: conn} do
      conn = get(conn, "/activate")

      assert html_response(conn, 200) =~ "Request activation code"
    end

    test "if user does have a code: prompts user to enter the activation code from their email",
         %{conn: conn} do
      conn =
        post(conn, "/activate/request-code")
        |> get("/activate")

      assert html_response(conn, 200) =~ "Please enter the 4-digit code we sent to"
    end
  end

  describe "POST /activate/request-code" do
    setup [:create_user, :log_in]

    test "associates an activation pin with the user account", %{conn: conn, user: user} do
      post(conn, "/activate/request-code")

      code =
        Repo.one(
          from c in "email_verification_codes",
            where: c.user_id == ^user.id,
            select: %{user_id: c.user_id, issued_at: c.issued_at}
        )

      assert code[:user_id] == user.id
      assert Timex.after?(code[:issued_at], Timex.now() |> Timex.shift(seconds: -10))
    end

    test "sends activation email to user", %{conn: conn, user: user} do
      post(conn, "/activate/request-code")

      assert_delivered_email_matches(%{to: [{_, user_email}], subject: subject})
      assert user_email == user.email
      assert subject =~ "is your Plausible email verification code"
    end
  end

  describe "POST /activate" do
    setup [:create_user, :log_in]

    test "with wrong pin - reloads the form with error", %{conn: conn} do
      conn = post(conn, "/activate", %{code: "1234"})

      assert html_response(conn, 200) =~ "Incorrect activation code"
    end

    test "with expired pin - reloads the form with error", %{conn: conn, user: user} do
      Repo.insert_all("email_verification_codes", [
        %{
          code: 1234,
          user_id: user.id,
          issued_at: Timex.shift(Timex.now(), days: -1)
        }
      ])

      conn = post(conn, "/activate", %{code: "1234"})

      assert html_response(conn, 200) =~ "Code is expired, please request another one"
    end

    test "marks the user account as active", %{conn: conn, user: user} do
      Repo.update!(Plausible.Auth.User.changeset(user, %{email_verified: false}))
      post(conn, "/activate/request-code")

      code =
        Repo.one(
          from c in "email_verification_codes", where: c.user_id == ^user.id, select: c.code
        )
        |> Integer.to_string()

      conn = post(conn, "/activate", %{code: code})
      user = Repo.get_by(Plausible.Auth.User, id: user.id)

      assert user.email_verified
      assert redirected_to(conn) == "/sites/new"
    end

    test "removes the user association from the verification code", %{conn: conn, user: user} do
      Repo.update!(Plausible.Auth.User.changeset(user, %{email_verified: false}))
      post(conn, "/activate/request-code")

      code =
        Repo.one(
          from c in "email_verification_codes", where: c.user_id == ^user.id, select: c.code
        )
        |> Integer.to_string()

      post(conn, "/activate", %{code: code})

      refute Repo.exists?(from c in "email_verification_codes", where: c.user_id == ^user.id)
    end
  end

  describe "GET /login_form" do
    test "shows the login form", %{conn: conn} do
      conn = get(conn, "/login")
      assert html_response(conn, 200) =~ "Enter your email and password"
    end
  end

  describe "POST /login" do
    test "valid email and password - logs the user in", %{conn: conn} do
      user = insert(:user, password: "password")

      conn = post(conn, "/login", email: user.email, password: "password")

      assert get_session(conn, :current_user_id) == user.id
      assert redirected_to(conn) == "/sites"
    end

    test "email does not exist - renders login form again", %{conn: conn} do
      conn = post(conn, "/login", email: "user@example.com", password: "password")

      assert get_session(conn, :current_user_id) == nil
      assert html_response(conn, 200) =~ "Enter your email and password"
    end

    test "bad password - renders login form again", %{conn: conn} do
      user = insert(:user, password: "password")
      conn = post(conn, "/login", email: user.email, password: "wrong")

      assert get_session(conn, :current_user_id) == nil
      assert html_response(conn, 200) =~ "Enter your email and password"
    end
  end

  describe "GET /password/request-reset" do
    test "renders the form", %{conn: conn} do
      conn = get(conn, "/password/request-reset")
      assert html_response(conn, 200) =~ "Enter your email so we can send a password reset link"
    end
  end

  describe "POST /password/request-reset" do
    test "email is empty - renders form with error", %{conn: conn} do
      conn = post(conn, "/password/request-reset", %{email: ""})

      assert html_response(conn, 200) =~ "Enter your email so we can send a password reset link"
    end

    test "email is present and exists - sends password reset email", %{conn: conn} do
      user = insert(:user)
      conn = post(conn, "/password/request-reset", %{email: user.email})

      assert html_response(conn, 200) =~ "Success!"
      assert_email_delivered_with(subject: "Plausible password reset")
    end
  end

  describe "GET /password/reset" do
    test "with valid token - shows form", %{conn: conn} do
      token = Plausible.Auth.Token.sign_password_reset("email@example.com")
      conn = get(conn, "/password/reset", %{token: token})

      assert html_response(conn, 200) =~ "Reset your password"
    end

    test "with invalid token - shows error page", %{conn: conn} do
      conn = get(conn, "/password/reset", %{token: "blabla"})

      assert html_response(conn, 401) =~ "Your token is invalid"
    end
  end

  describe "POST /password/reset" do
    alias Plausible.Auth.{User, Token, Password}

    test "with valid token - resets the password", %{conn: conn} do
      user = insert(:user)
      token = Token.sign_password_reset(user.email)
      post(conn, "/password/reset", %{token: token, password: "new-password"})

      user = Plausible.Repo.get(User, user.id)
      assert Password.match?("new-password", user.password_hash)
    end
  end

  describe "GET /settings" do
    setup [:create_user, :log_in]

    test "shows the form", %{conn: conn} do
      conn = get(conn, "/settings")
      assert html_response(conn, 200) =~ "Account settings"
    end

    test "shows subscription", %{conn: conn, user: user} do
      insert(:subscription, paddle_plan_id: "558018", user: user)
      conn = get(conn, "/settings")
      assert html_response(conn, 200) =~ "10k pageviews"
      assert html_response(conn, 200) =~ "monthly billing"
    end
  end

  describe "PUT /settings" do
    setup [:create_user, :log_in]

    test "updates user record", %{conn: conn, user: user} do
      put(conn, "/settings", %{"user" => %{"name" => "New name"}})

      user = Plausible.Repo.get(Plausible.Auth.User, user.id)
      assert user.name == "New name"
    end
  end

  describe "DELETE /me" do
    setup [:create_user, :log_in, :create_site]
    use Plausible.Repo

    test "deletes the user", %{conn: conn, user: user, site: site} do
      Repo.insert_all("intro_emails", [
        %{
          user_id: user.id,
          timestamp: NaiveDateTime.utc_now()
        }
      ])

      Repo.insert_all("feedback_emails", [
        %{
          user_id: user.id,
          timestamp: NaiveDateTime.utc_now()
        }
      ])

      Repo.insert_all("create_site_emails", [
        %{
          user_id: user.id,
          timestamp: NaiveDateTime.utc_now()
        }
      ])

      Repo.insert_all("check_stats_emails", [
        %{
          user_id: user.id,
          timestamp: NaiveDateTime.utc_now()
        }
      ])

      insert(:google_auth, site: site, user: user)
      insert(:subscription, user: user, status: "deleted")

      conn = delete(conn, "/me")
      assert redirected_to(conn) == "/"
    end
  end
end
