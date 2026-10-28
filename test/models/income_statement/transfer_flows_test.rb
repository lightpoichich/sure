require "test_helper"

class IncomeStatement::TransferFlowsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @month = Date.new(2024, 2, 1)
    @checking, @joint, @savings = %w[Checking Joint Savings].map do |name|
      @family.accounts.create!(name: name, currency: "USD", balance: 0, accountable: Depository.new)
    end
  end

  test "what the selected accounts sent each other account, net of what came back" do
    transfer(@checking, @joint, 600)
    transfer(@checking, @savings, 500)
    transfer(@savings, @checking, 200)

    assert_equal({ @joint.id => 600.to_d, @savings.id => 300.to_d }, flows.sent_outside([ @checking.id ]))
  end

  test "transfers between two selected accounts cancel out" do
    transfer(@checking, @savings, 500)
    transfer(@savings, @joint, 100)

    assert_equal({ @joint.id => 100.to_d }, flows.sent_outside([ @checking.id, @savings.id ]))
  end

  test "an account that sent the selection more than it received is not an outflow" do
    transfer(@joint, @checking, 700)
    transfer(@checking, @joint, 100)

    assert_empty flows.sent_outside([ @checking.id ])
  end

  test "pending matches and transfers outside the period are left out" do
    transfer(@checking, @joint, 300).update!(status: "pending")
    create_transfer(from_account: @checking, to_account: @savings, amount: 200, date: @month - 1.day)

    assert_empty flows.totals
  end

  private
    def transfer(from, to, amount)
      create_transfer(from_account: from, to_account: to, amount: amount, date: @month)
    end

    def flows
      IncomeStatement::TransferFlows.new(IncomeStatement.new(@family), period: Period.custom(start_date: @month, end_date: @month.end_of_month))
    end
end
