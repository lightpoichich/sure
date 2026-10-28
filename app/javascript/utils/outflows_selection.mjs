// The Outflows donut's live category filter: which segments stay drawn once
// some categories are unchecked, and how the total and shares read then.
//
// The total is the sum of the checked segments, and each share is recomputed
// against it, rounded to one decimal like the server's weights.
export function selectSegments(segments, selectedIds) {
  const selected = segments.filter((segment) => selectedIds.has(String(segment.id)));
  const total = selected.reduce((sum, segment) => sum + Number(segment.amount), 0);

  return {
    total: Math.round(total * 100) / 100,
    segments: selected.map((segment) => ({
      ...segment,
      percentage: total > 0 ? Math.round((Number(segment.amount) / total) * 1000) / 10 : 0,
    })),
  };
}

// Same form as the server's "38.7%": always one decimal.
export function formatPercentage(percentage) {
  return `${Number(percentage).toFixed(1)}%`;
}

// Formats like the server's Money#format (ActiveSupport number_to_currency),
// from the options Money#format_options gives for the currency and locale:
// unit, precision, delimiter, separator and a "%u"/"%n" format. Intl would
// follow CLDR instead and disagree with the amounts the server rendered.
export function formatMoney(amount, { unit, precision, delimiter, separator, format }) {
  const [integer, fraction] = Math.abs(Number(amount)).toFixed(precision).split(".");
  const grouped = integer.replace(/\B(?=(\d{3})+(?!\d))/g, delimiter);
  const number = `${Number(amount) < 0 ? "-" : ""}${fraction ? `${grouped}${separator}${fraction}` : grouped}`;
  return format.replace("%n", number).replace("%u", unit);
}
