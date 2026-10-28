require "test_helper"

class IncomeStatement::AccountSankeyTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @checking = @family.accounts.create!(name: "Checking", currency: "USD", balance: 0, accountable: Depository.new)
    @card = @family.accounts.create!(name: "Card", currency: "USD", balance: 0, accountable: CreditCard.new)
    @month = Date.new(2024, 2, 1)
    @salary = @family.categories.create!(name: "Salary", color: "#00aa00")
    @shopping = @family.categories.create!(name: "Shopping", color: "#123456")
    @groceries = @family.categories.create!(name: "Groceries", parent: @shopping)
  end

  test "flows run from income categories through each account to expense categories" do
    transaction(@checking, -1000, @salary)
    transaction(@checking, 300, @shopping)
    transaction(@card, 200, @groceries)
    result = graph

    assert_equal "net_by_account", result[:basis]
    assert_equal "1000.0", result[:income]
    assert_equal "500.0", result[:spending]
    assert_equal "500.0", result[:net_savings]
    assert_nil node(result, "cash_flow_node")
    assert_equal "account", node(result, "account_#{@checking.id}")[:kind]
    assert_link result, "income_#{@salary.id}", "account_#{@checking.id}", "1000.0"
    assert_link result, "account_#{@checking.id}", "expense_#{@shopping.id}", "300.0"
    assert_link result, "account_#{@card.id}", "expense_#{@shopping.id}", "200.0"
    assert_equal "500.0", node(result, "expense_#{@shopping.id}")[:value], "one category node across accounts"
    assert_link result, "expense_#{@shopping.id}", "expense_sub_#{@groceries.id}", "200.0"
    assert_equal @groceries.filter_value, node(result, "expense_sub_#{@groceries.id}")[:filter_value]
    assert_balanced result
  end

  test "an account taking in more than it spends feeds Surplus, one spending more is fed by Deficit" do
    transaction(@checking, -1000, @salary)
    transaction(@checking, 100, @shopping)
    transaction(@card, 250, @shopping)
    result = graph

    assert_link result, "account_#{@checking.id}", "surplus_node", "900.0"
    assert_link result, "deficit_node", "account_#{@card.id}", "250.0"
    assert_equal "900.0", node(result, "surplus_node")[:value]
    assert_equal "250.0", node(result, "deficit_node")[:value]
    assert_balanced result
  end

  test "money invested leaves each account for Invested when investing is not spending" do
    @family.update!(investment_contributions_as_spending: false)
    transaction(@checking, -1000, @salary)
    transaction(@checking, 200, @shopping)
    create_transaction(account: @checking, amount: 300, category: nil, date: @month, kind: "investment_contribution")
    result = graph

    assert_equal "300.0", result[:invested]
    assert_link result, "account_#{@checking.id}", "invested_node", "300.0"
    assert_link result, "account_#{@checking.id}", "surplus_node", "500.0"
    assert_balanced result
  end

  test "accounts without income or spending are left out, and an empty period is empty" do
    transaction(@checking, 50, @shopping)
    assert_nil node(graph, "account_#{@card.id}")
    assert_equal({ nodes: [], links: [] }, graph(Date.new(2023, 1, 1)).slice(:nodes, :links))
  end

  test "a transfer between reported accounts flows from one account node to the other" do
    joint = depository("Joint")
    transaction(@checking, -1000, @salary)
    transaction(@checking, 100, @shopping)
    transfer(@checking, joint, 600)
    transaction(joint, 500, @groceries)
    result = graph

    assert_equal "1000.0", result[:income], "a transfer is neither income"
    assert_equal "600.0", result[:spending], "nor spending"
    assert_link result, "account_#{@checking.id}", "account_#{joint.id}", "600.0"
    assert_link result, "account_#{@checking.id}", "surplus_node", "300.0"
    assert_link result, "account_#{joint.id}", "surplus_node", "100.0"
    assert_balanced result
  end

  test "savings drawn down feed their account through Deficit, then flow on to the accounts they paid" do
    savings, reserve, joint = depository("Savings"), depository("Reserve"), depository("Joint")
    transfer(savings, @checking, 400)
    transfer(reserve, joint, 300)
    transaction(@checking, 150, @shopping)
    result = graph

    assert_link result, "deficit_node", "account_#{savings.id}", "400.0"
    assert_link result, "account_#{savings.id}", "account_#{@checking.id}", "400.0"
    assert_link result, "account_#{@checking.id}", "surplus_node", "250.0"
    assert_equal "700.0", node(result, "deficit_node")[:value]
    assert_equal "100.0", node(result, "deficit_node")[:percentage], "Deficit is the widest node here"
    assert_balanced result
  end

  test "transfers both ways between two accounts are netted to one direction" do
    savings = depository("Savings")
    transaction(@checking, -1000, @salary)
    transfer(@checking, savings, 500)
    transfer(savings, @checking, 200)
    result = graph

    assert_link result, "account_#{@checking.id}", "account_#{savings.id}", "300.0"
    assert_no_link result, "account_#{savings.id}", "account_#{@checking.id}"
    assert_balanced result
  end

  test "a cycle of transfers is cancelled without changing what each account gains" do
    savings, joint = depository("Savings"), depository("Joint")
    transaction(@checking, -1000, @salary)
    transfer(@checking, savings, 300)
    transfer(savings, joint, 200)
    transfer(joint, @checking, 100)
    result = graph

    assert_link result, "account_#{@checking.id}", "account_#{savings.id}", "200.0"
    assert_link result, "account_#{savings.id}", "account_#{joint.id}", "100.0"
    assert_no_link result, "account_#{joint.id}", "account_#{@checking.id}"
    assert_link result, "account_#{@checking.id}", "surplus_node", "800.0"
    assert_link result, "account_#{savings.id}", "surplus_node", "100.0"
    assert_link result, "account_#{joint.id}", "surplus_node", "100.0"
    assert_balanced result
  end

  test "a transfer to an account left out of reports stays invisible" do
    hidden = depository("Hidden", exclude_from_reports: true)
    transaction(@checking, -1000, @salary)
    transfer(@checking, hidden, 300)
    result = graph

    assert_nil node(result, "account_#{hidden.id}")
    assert_link result, "account_#{@checking.id}", "surplus_node", "1000.0"
    assert_balanced result
  end

  test "a transfer falls in the period its money left the account" do
    savings = depository("Savings")
    transaction(@checking, -1000, @salary)
    straddling = create_transfer(from_account: @checking, to_account: savings, amount: 300, date: @month - 1.day)
    straddling.inflow_transaction.reload.entry.update!(date: @month)
    result = graph

    assert_nil node(result, "account_#{savings.id}"), "the inflow leg alone draws nothing"
    assert_link result, "account_#{@checking.id}", "surplus_node", "1000.0"
    assert_link graph(@month.prev_month), "account_#{@checking.id}", "account_#{savings.id}", "300.0"
  end

  test "pending matches and other transfer kinds are not drawn between accounts" do
    savings = depository("Savings")
    transaction(@checking, -1000, @salary)
    pending = transfer(@checking, savings, 200)
    pending.update!(status: "pending")
    pending.inflow_transaction.update!(kind: "standard")
    payment = transfer(@checking, @card, 100)
    payment.outflow_transaction.update!(kind: "cc_payment")
    result = graph

    assert_no_link result, "account_#{@checking.id}", "account_#{savings.id}"
    assert_no_link result, "account_#{@checking.id}", "account_#{@card.id}"
    assert_link result, "income_uncategorized", "account_#{savings.id}", "200.0"
    assert_link result, "account_#{@checking.id}", "surplus_node", "1000.0"
    assert_balanced result
  end

  test "a category's per-account netting matches the category view" do
    transaction(@checking, 120, @shopping)
    transaction(@checking, -20, @shopping)
    result = graph
    by_category = IncomeStatement::Sankey.new(IncomeStatement.new(@family), period: period).as_json

    assert_equal by_category[:spending], result[:spending]
    assert_equal node(by_category, "expense_#{@shopping.id}")[:value], node(result, "expense_#{@shopping.id}")[:value]
  end

  private
    def transaction(account, amount, category)
      create_transaction(account: account, amount: amount, category: category, date: @month)
    end

    def transfer(from, to, amount)
      create_transfer(from_account: from, to_account: to, amount: amount, date: @month)
    end

    def depository(name, **attributes)
      @family.accounts.create!(name: name, currency: "USD", balance: 0, accountable: Depository.new, **attributes)
    end

    def period(month = @month)
      Period.custom(start_date: month, end_date: month.end_of_month)
    end

    def graph(month = @month)
      IncomeStatement::AccountSankey.new(IncomeStatement.new(@family), period: period(month)).as_json
    end

    def node(graph, id)
      graph[:nodes].find { |node| node[:id] == id }
    end

    def assert_link(graph, source_id, target_id, value)
      ids = graph[:nodes].map { |node| node[:id] }
      link = graph[:links].find { |l| l[:source] == ids.index(source_id) && l[:target] == ids.index(target_id) }
      assert link, "expected a link #{source_id} -> #{target_id}"
      assert_equal value, link[:value]
    end

    def assert_no_link(graph, source_id, target_id)
      ids = graph[:nodes].map { |node| node[:id] }
      assert_not graph[:links].any? { |l| l[:source] == ids.index(source_id) && l[:target] == ids.index(target_id) },
        "expected no link #{source_id} -> #{target_id}"
    end

    # Every account balances, and every node's value is its larger side.
    def assert_balanced(graph)
      graph[:nodes].each_with_index do |node, index|
        incoming, outgoing = %i[target source].map do |end_point|
          graph[:links].select { |link| link[end_point] == index }.sum { |link| link[:value].to_d }
        end
        assert_operator node[:value].to_d, :>, 0
        assert_operator node[:percentage].to_d, :<=, 100
        assert_equal incoming, outgoing, "#{node[:id]} must balance" if node[:kind] == "account"
        assert_equal node[:value].to_d, [ incoming, outgoing ].max, "#{node[:id]} must match its links' capacity"
      end
    end
end
