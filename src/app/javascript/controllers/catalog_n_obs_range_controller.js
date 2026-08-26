import { Controller } from "@hotwired/stimulus"

// Dual-thumb range for external catalog n_obs (cells/samples) filtering.
// Range inputs use a log scale so small and large matrices remain usable.
export default class extends Controller {
  static targets = [
    "minRange",
    "maxRange",
    "minField",
    "maxField",
    "minDisplay",
    "maxDisplay",
    "fill"
  ]

  static values = {
    boundMin: Number,
    boundMax: Number,
    steps: { type: Number, default: 1000 }
  }

  connect() {
    this.syncRangesFromFields()
    this.updateUI()
  }

  minRangeInput() {
    let minPos = this.toInt(this.minRangeTarget.value)
    const maxPos = this.toInt(this.maxRangeTarget.value)
    if (minPos > maxPos) {
      minPos = maxPos
      this.minRangeTarget.value = String(minPos)
    }
    this.minFieldTarget.value = String(this.positionToValue(minPos))
    this.preferHandle(this.minRangeTarget)
    this.updateUI()
  }

  maxRangeInput() {
    const minPos = this.toInt(this.minRangeTarget.value)
    let maxPos = this.toInt(this.maxRangeTarget.value)
    if (maxPos < minPos) {
      maxPos = minPos
      this.maxRangeTarget.value = String(maxPos)
    }
    this.maxFieldTarget.value = String(this.positionToValue(maxPos))
    this.preferHandle(this.maxRangeTarget)
    this.updateUI()
  }

  // Fired when the user finishes moving a thumb; refreshes results.
  commit() {
    this.element.closest("form")?.requestSubmit()
  }

  preferHandle(active) {
    this.minRangeTarget.style.zIndex = active === this.minRangeTarget ? "3" : "2"
    this.maxRangeTarget.style.zIndex = active === this.maxRangeTarget ? "3" : "2"
  }

  syncRangesFromFields() {
    const minV = this.toInt(this.minFieldTarget.value)
    const maxV = this.toInt(this.maxFieldTarget.value)
    this.minRangeTarget.value = String(this.valueToPosition(minV))
    this.maxRangeTarget.value = String(this.valueToPosition(maxV))
  }

  updateUI() {
    const minV = this.toInt(this.minFieldTarget.value)
    const maxV = this.toInt(this.maxFieldTarget.value)
    if (this.hasMinDisplayTarget) {
      this.minDisplayTarget.textContent = this.formatNumber(minV)
    }
    if (this.hasMaxDisplayTarget) {
      this.maxDisplayTarget.textContent = this.formatNumber(maxV)
    }
    if (this.hasFillTarget) {
      const minPct = (this.toInt(this.minRangeTarget.value) / this.stepsValue) * 100
      const maxPct = (this.toInt(this.maxRangeTarget.value) / this.stepsValue) * 100
      this.fillTarget.style.left = `${minPct}%`
      this.fillTarget.style.width = `${Math.max(maxPct - minPct, 0)}%`
    }
  }

  valueToPosition(value) {
    const boundMin = Math.max(this.boundMinValue, 1)
    const boundMax = Math.max(this.boundMaxValue, boundMin)
    const v = Math.min(Math.max(value, this.boundMinValue), this.boundMaxValue)
    if (boundMax === boundMin) return 0
    const logMin = Math.log10(boundMin)
    const logMax = Math.log10(boundMax)
    const logV = Math.log10(Math.max(v, 1))
    const t = (logV - logMin) / (logMax - logMin)
    return Math.round(Math.min(Math.max(t, 0), 1) * this.stepsValue)
  }

  positionToValue(pos) {
    const boundMin = Math.max(this.boundMinValue, 1)
    const boundMax = Math.max(this.boundMaxValue, boundMin)
    if (boundMax === boundMin) return this.boundMinValue
    const t = Math.min(Math.max(pos, 0), this.stepsValue) / this.stepsValue
    const logMin = Math.log10(boundMin)
    const logMax = Math.log10(boundMax)
    const value = Math.round(Math.pow(10, logMin + t * (logMax - logMin)))
    return Math.min(Math.max(value, this.boundMinValue), this.boundMaxValue)
  }

  formatNumber(n) {
    return Number(n).toLocaleString("en-US")
  }

  toInt(raw) {
    return parseInt(String(raw).replace(/,/g, ""), 10)
  }
}
