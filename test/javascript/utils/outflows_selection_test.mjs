import assert from "node:assert/strict";
import test from "node:test";

import {
  formatMoney,
  formatPercentage,
  selectSegments,
} from "../../../app/javascript/utils/outflows_selection.mjs";

const segments = [
  { id: "rent", amount: 700, percentage: 70 },
  { id: "food", amount: 200, percentage: 20 },
  { id: "account_joint", amount: 100, percentage: 10 },
];

test("keeps only the checked segments and shares them out again", () => {
  const { total, segments: selected } = selectSegments(segments, new Set(["food", "account_joint"]));

  assert.equal(total, 300);
  assert.deepEqual(
    selected.map((segment) => [segment.id, segment.percentage]),
    [
      ["food", 66.7],
      ["account_joint", 33.3],
    ],
  );
});

test("everything checked is the server's view", () => {
  const { total, segments: selected } = selectSegments(segments, new Set(["rent", "food", "account_joint"]));

  assert.equal(total, 1000);
  assert.deepEqual(
    selected.map((segment) => segment.percentage),
    [70, 20, 10],
  );
});

test("nothing checked is an empty donut with a zero total", () => {
  assert.deepEqual(selectSegments(segments, new Set()), { total: 0, segments: [] });
});

test("matches ids whatever their type", () => {
  const { total } = selectSegments([{ id: 42, amount: 5 }], new Set(["42"]));
  assert.equal(total, 5);
});

test("rounds the total to cents", () => {
  const { total } = selectSegments(
    [
      { id: "a", amount: 0.1 },
      { id: "b", amount: 0.2 },
    ],
    new Set(["a", "b"]),
  );
  assert.equal(total, 0.3);
});

test("formats shares with one decimal, like the server", () => {
  assert.equal(formatPercentage(12), "12.0%");
  assert.equal(formatPercentage(66.7), "66.7%");
});

test("formats money in the page's locale", () => {
  assert.equal(formatMoney(3000, "USD", "en"), "$3,000.00");
  assert.equal(formatMoney(1, "XXX-not-a-currency", "en"), "1");
});
