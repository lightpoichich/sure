require "application_system_test_case"

class DashboardOutflowsFilterTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    # The expected amounts below are the en/USD rendering.
    @user.update!(locale: "en")
    family = @user.family
    account = family.accounts.create!(name: "Filter checking", owner: @user, currency: family.currency, balance: 0, accountable: Depository.new)
    @rent = family.categories.create!(name: "Filter rent", color: "#6471eb")
    @food = family.categories.create!(name: "Filter food", color: "#e99537")
    create_transaction(account: account, amount: 7000, category: @rent, date: Date.current, currency: family.currency)
    create_transaction(account: account, amount: 3000, category: @food, date: Date.current, currency: family.currency)
  end

  test "unchecking categories takes them out of the donut's total and shares" do
    sign_in @user

    within "#outflows-donut-section" do
      total = "[data-outflows-filter-target='total']"
      everything = find(total).text

      find("input[data-outflows-filter-target='all']").uncheck
      assert_selector total, exact_text: "$0.00"
      assert_no_selector "[data-outflows-filter-target='donut'] path.visible-path", visible: :all

      find("input[data-outflows-filter-target='checkbox'][value='#{@food.id}']").check
      assert_selector total, exact_text: "$3,000.00"
      assert_selector "[data-outflows-filter-target='row'][data-category-id='#{@food.id}'] [data-outflows-filter-target='percentage']", exact_text: "100.0%"
      assert_selector "[data-outflows-filter-target='row'][data-category-id='#{@rent.id}'].opacity-50"
      assert_selector "[data-outflows-filter-target='donut'] path.visible-path", count: 1, visible: :all

      find("input[data-outflows-filter-target='all']").check
      assert_selector total, exact_text: everything
      assert_no_selector "[data-outflows-filter-target='row'].opacity-50"
    end
  end
end
