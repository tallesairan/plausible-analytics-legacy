defmodule Plausible.Billing.SiteLockerTest do
  use Plausible.DataCase
  use Bamboo.Test, shared: true
  alias Plausible.Billing.SiteLocker

  describe "check_sites_for/1" do
    test "does not lock sites if user is on trial" do
      user =
        insert(:user, trial_expiry_date: Timex.today())
        |> Repo.preload(:subscription)

      site = insert(:site, locked: true, members: [user])

      SiteLocker.check_sites_for(user)

      refute Repo.reload!(site).locked
    end

    test "does not lock if user has an active subscription" do
      user = insert(:user)
      insert(:subscription, status: "active", user: user)
      user = Repo.preload(user, :subscription)
      site = insert(:site, locked: true, members: [user])

      SiteLocker.check_sites_for(user)

      refute Repo.reload!(site).locked
    end

    test "does not lock user who is past due" do
      user = insert(:user)
      insert(:subscription, status: "past_due", user: user)
      user = Repo.preload(user, :subscription)
      site = insert(:site, members: [user])

      SiteLocker.check_sites_for(user)

      refute Repo.reload!(site).locked
    end

    test "does not lock user who cancelled subscription but it hasn't expired yet" do
      user = insert(:user)
      insert(:subscription, status: "deleted", user: user)
      user = Repo.preload(user, :subscription)
      site = insert(:site, members: [user])

      SiteLocker.check_sites_for(user)

      refute Repo.reload!(site).locked
    end

    test "locks user who cancelled subscription and the cancelled subscription has expired" do
      user = insert(:user)

      insert(:subscription,
        status: "deleted",
        next_bill_date: Timex.today() |> Timex.shift(days: -1),
        user: user
      )

      site = insert(:site, members: [user])

      user = Repo.preload(user, :subscription)

      SiteLocker.check_sites_for(user)

      refute Repo.reload!(site).locked
    end

    test "locks all sites if user has no trial or active subscription" do
      user =
        insert(:user, trial_expiry_date: Timex.today() |> Timex.shift(days: -1))
        |> Repo.preload(:subscription)

      site = insert(:site, locked: true, members: [user])

      SiteLocker.check_sites_for(user)

      assert Repo.reload!(site).locked
    end

    test "only locks sites that the user owns" do
      user =
        insert(:user, trial_expiry_date: Timex.today() |> Timex.shift(days: -1))
        |> Repo.preload(:subscription)

      owner_site =
        insert(:site,
          memberships: [
            build(:site_membership, user: user, role: :owner)
          ]
        )

      viewer_site =
        insert(:site,
          memberships: [
            build(:site_membership, user: user, role: :viewer)
          ]
        )

      SiteLocker.check_sites_for(user)

      owner_site = Repo.reload!(owner_site)
      viewer_site = Repo.reload!(viewer_site)

      assert owner_site.locked
      refute viewer_site.locked
    end
  end
end
