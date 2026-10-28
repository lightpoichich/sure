import { Controller } from "@hotwired/stimulus";
import { formatMoney, formatPercentage, selectSegments } from "utils/outflows_selection";

// Live category filter on the dashboard's Outflows widget. Unchecking a row
// takes its segment out of the donut, and the total and every share are
// recomputed over the rows left checked. Nothing goes back to the server: the
// selection lasts until the widget is reloaded.
export default class extends Controller {
  static targets = ["donut", "checkbox", "all", "total", "percentage", "row"];
  static values = { segments: Array, currency: String, locale: String };

  toggle() {
    this.#update();
  }

  toggleAll(event) {
    for (const checkbox of this.checkboxTargets) checkbox.checked = event.target.checked;
    this.#update();
  }

  #update() {
    const checked = new Set(this.checkboxTargets.filter((checkbox) => checkbox.checked).map((checkbox) => checkbox.value));
    const { total, segments } = selectSegments(this.segmentsValue, checked);
    const shares = new Map(segments.map((segment) => [String(segment.id), segment.percentage]));

    this.donutTarget.setAttribute("data-donut-chart-segments-value", JSON.stringify(segments));

    for (const element of this.totalTargets) {
      element.textContent = formatMoney(total, this.currencyValue, this.localeValue);
    }
    for (const element of this.percentageTargets) {
      const share = shares.get(element.dataset.categoryId);
      element.textContent = share === undefined ? "–" : formatPercentage(share);
    }
    for (const row of this.rowTargets) {
      row.classList.toggle("opacity-50", !checked.has(row.dataset.categoryId));
    }

    if (this.hasAllTarget) {
      this.allTarget.checked = checked.size === this.checkboxTargets.length;
      this.allTarget.indeterminate = checked.size > 0 && checked.size < this.checkboxTargets.length;
    }
  }
}
