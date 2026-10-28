import { Controller } from "@hotwired/stimulus";
import { formatMoney, formatPercentage, selectSegments } from "utils/outflows_selection";

// Live category filter on the dashboard's Outflows widget. Unchecking a row
// takes its segment out of the donut, and the total and every share are
// recomputed over the rows left checked. Nothing goes back to the server: the
// selection lasts until the widget is rendered again (a reload, another
// dashboard control, a background sync's refresh).
//
// With every row checked, the widget reads exactly as the server rendered it:
// its total text and its shares, not ones recomputed from rounded amounts.
export default class extends Controller {
  static targets = ["donut", "checkbox", "all", "total", "percentage", "row"];
  static values = { segments: Array, moneyFormat: Object, renderedTotal: String };

  connect() {
    this.sync();
  }

  // Also run after a Turbo morph refresh or a restore from the page cache:
  // both bring the boxes back but not the select-all box's indeterminate state.
  sync() {
    this.#syncAll(this.#checkedIds());
  }

  toggle() {
    this.#update();
  }

  toggleAll(event) {
    for (const checkbox of this.checkboxTargets) checkbox.checked = event.target.checked;
    this.#update();
  }

  #update() {
    const checked = this.#checkedIds();
    const everything = checked.size === this.checkboxTargets.length;
    const selection = everything
      ? { total: null, segments: this.segmentsValue }
      : selectSegments(this.segmentsValue, checked);
    const shares = new Map(selection.segments.map((segment) => [String(segment.id), segment.percentage]));

    this.donutTarget.setAttribute("data-donut-chart-segments-value", JSON.stringify(selection.segments));

    for (const element of this.totalTargets) {
      element.textContent = everything ? this.renderedTotalValue : formatMoney(selection.total, this.moneyFormatValue);
    }
    for (const element of this.percentageTargets) {
      const share = shares.get(element.dataset.categoryId);
      element.textContent = share === undefined ? "–" : formatPercentage(share);
    }
    for (const row of this.rowTargets) {
      row.classList.toggle("opacity-50", !checked.has(row.dataset.categoryId));
    }

    this.#syncAll(checked);
  }

  #checkedIds() {
    return new Set(this.checkboxTargets.filter((checkbox) => checkbox.checked).map((checkbox) => checkbox.value));
  }

  #syncAll(checked) {
    if (!this.hasAllTarget) return;

    this.allTarget.checked = checked.size === this.checkboxTargets.length;
    this.allTarget.indeterminate = checked.size > 0 && checked.size < this.checkboxTargets.length;
  }
}
