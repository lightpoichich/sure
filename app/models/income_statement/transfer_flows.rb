# Money moved between the accounts an income statement reports on, by
# confirmed funds-movement transfers. Income and spending leave these out; the
# account views use them to show where money went between accounts. A caller
# can also count payments to credit cards and other liabilities (cc_payment
# outflow legs), which income and spending leave out too.
#
# Only a transfer whose two legs are excluded from income and spending counts,
# so no amount is counted twice: a pending auto-match, or a leg still
# classified as income, stays where the category view puts it. Both legs must
# sit in reported accounts (a transfer to an account left out of the report
# stays invisible), and a transfer falls in the period its outflow leg left the
# account.
class IncomeStatement::TransferFlows
  OUTFLOW_KINDS = %w[funds_movement cc_payment].freeze

  def initialize(statement, period:, outflow_kinds: %w[funds_movement])
    raise ArgumentError, "unsupported outflow kinds: #{outflow_kinds}" unless (outflow_kinds - OUTFLOW_KINDS).empty?

    @statement, @period, @outflow_kinds = statement, period, outflow_kinds
  end

  # Gross amounts keyed [from_account_id, to_account_id].
  def totals
    @totals ||= query_totals
  end

  # One direction per pair of accounts, with any cycle (A -> B -> C -> A)
  # cancelled, since a Sankey must stay acyclic. Neither step changes what an
  # account sends or receives on balance.
  def acyclic
    without_cycles(net_by_pair)
  end

  # What the given accounts sent, net of what came back, to each reported
  # account outside them, keyed by that account's id. Transfers between two of
  # the given accounts cancel out; an account that sent the group more than it
  # received is left out.
  def sent_outside(account_ids)
    inside = account_ids.map(&:to_s).to_set
    sent = Hash.new(0.to_d)
    totals.sort_by(&:first).each do |(from, to), amount|
      if inside.include?(from) && !inside.include?(to)
        sent[to] += amount.to_d
      elsif inside.include?(to) && !inside.include?(from)
        sent[from] -= amount.to_d
      end
    end
    sent.transform_values { |amount| amount.round(2) }.select { |_, amount| amount.positive? }
  end

  private
    def query_totals
      account_ids = @statement.eligible_accounts.pluck(:id)
      return {} if account_ids.size < 2

      family = @statement.family
      # The leg already in the family currency needs no rate; otherwise the
      # outflow converts at the day's rate, 1:1 when missing, like the rest of
      # the income statement.
      amount = ActiveRecord::Base.sanitize_sql([ <<~SQL.squish, family.currency, family.currency ])
        CASE
          WHEN entries.currency = ? THEN ABS(entries.amount)
          WHEN inflow_entries.currency = ? THEN ABS(inflow_entries.amount)
          ELSE ABS(entries.amount * COALESCE(er.rate, 1))
        END
      SQL

      family.transactions.excluding_pending
        .where(kind: @outflow_kinds, entries: { account_id: account_ids, date: @period.start_date..@period.end_date, excluded: false })
        .joins(:transfer_as_outflow)
        .where(transfers: { status: "confirmed" })
        .joins("JOIN transactions inflow_transactions ON inflow_transactions.id = transfers.inflow_transaction_id")
        .joins("JOIN entries inflow_entries ON inflow_entries.entryable_id = inflow_transactions.id AND inflow_entries.entryable_type = 'Transaction'")
        .joins(ActiveRecord::Base.sanitize_sql([
          "LEFT JOIN exchange_rates er ON er.date = entries.date AND er.from_currency = entries.currency AND er.to_currency = ?",
          family.currency
        ]))
        .where(inflow_transactions: { kind: "funds_movement" }, inflow_entries: { account_id: account_ids, excluded: false })
        .group("entries.account_id", "inflow_entries.account_id")
        .sum(Arel.sql(amount))
    end

    # What A sent B less what B sent A, rounded to cents so a round trip at two
    # exchange rates leaves no residue. Pairs are visited in id order, so cycle
    # cancellation never depends on the order rows come back from the database.
    def net_by_pair
      balances = Hash.new(0.to_d)
      totals.sort_by(&:first).each do |(from, to), amount|
        next if from == to

        pair = [ from, to ].sort
        balances[pair] += pair.first == from ? amount.to_d : -amount.to_d
      end

      balances.transform_values { |amount| amount.round(2) }.each_with_object({}) do |((first, second), amount), flows|
        if amount.positive?
          flows[[ first, second ]] = amount
        elsif amount.negative?
          flows[[ second, first ]] = -amount
        end
      end
    end

    # Cancels each cycle by its smallest flow until none is left. Every account
    # on a cycle sends and receives that amount once, so its balance is kept.
    def without_cycles(flows)
      flows = flows.dup
      while (cycle = find_cycle(flows))
        edges = cycle.each_cons(2).to_a
        smallest = edges.map { |edge| flows.fetch(edge) }.min
        edges.each do |edge|
          flows[edge] -= smallest
          flows.delete(edge) if flows[edge].zero?
        end
      end
      flows
    end

    # A cycle as a closed path [a, b, ..., a], or nil.
    def find_cycle(flows)
      successors = flows.keys.group_by(&:first).transform_values { |edges| edges.map(&:last) }
      finished = Set.new
      successors.each_key do |start|
        cycle = cycle_from(start, [], successors, finished)
        return cycle if cycle
      end
      nil
    end

    def cycle_from(node, path, successors, finished)
      return path.drop(path.index(node)) + [ node ] if path.include?(node)
      return if finished.include?(node)

      successors.fetch(node, []).each do |successor|
        cycle = cycle_from(successor, path + [ node ], successors, finished)
        return cycle if cycle
      end
      finished << node
      nil
    end
end
