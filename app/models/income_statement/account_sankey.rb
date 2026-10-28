# Cash-flow Sankey grouped by account: income categories -> accounts -> expense
# categories. Each account's categories are netted with IncomeStatement::
# CategoryNetting, scoped to that account. What an account takes in beyond what
# it spends flows on to Surplus; an account that spends more than it takes in
# (a credit card paid off by transfer, savings being drawn down) is fed from
# Deficit.
#
# Transfers between two reported accounts (funds movements) are neither income
# nor spending, so they never reach a category node: they flow from one account
# node to the other (checking -> joint account, savings -> checking). Each pair
# of accounts is netted to one direction, and any cycle left (A -> B -> C -> A)
# is cancelled, since a Sankey must stay acyclic. Neither step changes what an
# account sends or receives on balance, so Surplus and Deficit still show what
# each account gained or drew down.
#
# Same schema as IncomeStatement::Sankey, with basis "net_by_account" and an
# "account" node kind in place of the single Cash Flow node.
class IncomeStatement::AccountSankey
  ACCOUNT_COLOR = "#737373".freeze

  def initialize(statement, period:)
    @statement, @period = statement, period
  end

  def as_json(*)
    @nodes, @links, @node_index = [], [], {}
    transfers = transfer_flows
    flows = account_flows(transfers)
    income = flows.sum { |flow| flow[:income] }.to_d
    spending = flows.sum { |flow| flow[:spending] }.to_d
    invested = flows.sum { |flow| flow[:invested] }.to_d
    base = [ income, spending + invested ].max
    # Money moved between accounts can make an account, or Surplus and Deficit,
    # carry more than the family earned or spent, so their percentages are of
    # the widest node. Without transfers this is the base above.
    nets = flows.map { |flow| account_net(flow) }
    capacity = [ base, *flows.map { |flow| account_size(flow) }, nets.select(&:positive?).sum, -nets.select(&:negative?).sum ].max
    unless capacity.zero?
      subcategory_flows = Hash.new(0.to_d)
      flows.each { |flow| add_account(flow, income, spending, base, capacity, subcategory_flows) }
      add_transfers(transfers, capacity)
      add_subcategories(subcategory_flows)
    end
    { basis: "net_by_account", income: decimal(income), spending: decimal(spending), invested: decimal(invested),
      net_savings: decimal(income - spending), nodes: @nodes.map { |node| serialize(node) }, links: @links }
  end

  private
    # Accounts the statement reports on, each with its own netting. One scoped
    # statement per account keeps the netting identical to the category view.
    def account_flows(transfers)
      received, sent = Hash.new(0.to_d), Hash.new(0.to_d)
      transfers.each do |(from, to), amount|
        sent[from] += amount
        received[to] += amount
      end

      @statement.eligible_accounts.order(:name).filter_map do |account|
        statement = @statement.family.income_statement(user: @statement.user, accounts: Account.where(id: account.id))
        groups = IncomeStatement::CategoryNetting.new(statement, period: @period).groups
        income = groups.sum { |group| side_total(group, :income) }.to_d
        spending = groups.sum { |group| side_total(group, :expense) }.to_d
        # Zero unless the family stops counting investing as spending (#3952).
        invested = statement.invested_total(period: @period).amount.to_d
        transfers_in, transfers_out = received[account.id], sent[account.id]
        next if [ income, spending, invested, transfers_in, transfers_out ].all?(&:zero?)

        { account: account, groups: groups, income: income, spending: spending, invested: invested,
          transfers_in: transfers_in, transfers_out: transfers_out }
      end
    end

    # Netted per pair and acyclic: see IncomeStatement::TransferFlows.
    def transfer_flows
      IncomeStatement::TransferFlows.new(@statement, period: @period).acyclic
    end

    def account_size(flow)
      [ flow[:income] + flow[:transfers_in], flow[:spending] + flow[:invested] + flow[:transfers_out] ].max
    end

    # What the account gained (positive) or drew down (negative) over the period.
    def account_net(flow)
      flow[:income] + flow[:transfers_in] - flow[:spending] - flow[:invested] - flow[:transfers_out]
    end

    def add_account(flow, income, spending, base, capacity, subcategory_flows)
      account = flow[:account]
      size = account_size(flow)
      center = account_node(account)
      center[:value] = size
      center[:percentage] = percentage(size, capacity)

      flow[:groups].each do |group|
        { income: income, expense: spending }.each do |side, side_total|
          amount = side_total(group, side)
          next if amount.zero?

          category = group[:category]
          root = node("#{side}_#{category_key(category)}", category.name, side, category: category)
          root[:value] += amount
          root[:percentage] = percentage(root[:value], side_total)
          link(*(side == :income ? [ root, center ] : [ center, root ]), amount, percentage(amount, side_total))
          group[:children].each do |child|
            value = side_amount(child[:net], side)
            subcategory_flows[[ side, root[:id], child[:category] ]] += value unless value.zero?
          end
        end
      end

      if flow[:invested].positive?
        node_invested = node("invested_node", "Invested", :invested, color: IncomeStatement::Sankey::INVESTED_COLOR)
        node_invested[:value] += flow[:invested]
        node_invested[:percentage] = percentage(node_invested[:value], base)
        link(center, node_invested, flow[:invested], percentage(flow[:invested], base))
      end

      net = account_net(flow)
      return if net.zero?

      kind = net.positive? ? :surplus : :deficit
      balance = node("#{kind}_node", kind.to_s.capitalize, kind)
      balance[:value] += net.abs
      balance[:percentage] = percentage(balance[:value], capacity)
      link(*(net.positive? ? [ center, balance ] : [ balance, center ]), net.abs, percentage(net.abs, capacity))
    end

    # Every account a transfer touches has a node by now: its transfers alone
    # keep it in account_flows.
    def add_transfers(transfers, capacity)
      transfers.each do |(from, to), amount|
        link(@node_index.fetch("account_#{from}"), @node_index.fetch("account_#{to}"), amount, percentage(amount, capacity))
      end
    end

    # Subcategories are summed across accounts, then hang off their parent.
    def add_subcategories(subcategory_flows)
      subcategory_flows.each do |(side, root_id, category), value|
        root = @node_index.fetch(root_id)
        child = node("#{side}_sub_#{category.id}", category.name, side, category: category)
        child[:value] += value
        child[:percentage] = percentage(child[:value], root[:value])
        link(*(side == :income ? [ child, root ] : [ root, child ]), value, percentage(value, root[:value]))
      end
    end

    def account_node(account)
      node("account_#{account.id}", account.name, :account, color: ACCOUNT_COLOR)
    end

    def node(id, name, kind, category: nil, color: category&.color)
      @node_index[id] ||= begin
        @nodes << { id: id, index: @nodes.size, name: name, kind: kind.to_s, value: 0.to_d, percentage: 0,
          category_id: category&.id, filter_value: category && !category.other_investments? ? category.filter_value : nil,
          color: color }
        @nodes.last
      end
    end

    def link(source, target, value, percentage)
      @links << { source: source[:index], target: target[:index], value: decimal(value), percentage: decimal(percentage) }
    end

    def serialize(node)
      node.except(:index).merge(value: decimal(node[:value]), percentage: decimal(node[:percentage]))
    end

    def category_key(category) = IncomeStatement::CategoryNetting.key(category)
    def side_amount(net, side) = IncomeStatement::CategoryNetting.side_amount(net, side)
    def side_total(group, side) = IncomeStatement::CategoryNetting.side_total(group, side)

    def percentage(value, total)
      total.zero? ? 0 : (value.to_d / total * 100).round(1)
    end

    def decimal(value)
      value.to_d.to_s("F")
    end
end
