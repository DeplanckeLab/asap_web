/**
 * Resolves references like #input_matrix.nber_cols|min inside expressions.
 * Hidden input_data values are JSON: a single object or an array of objects
 * (run_id, annot_id, nber_rows, nber_cols, ...).
 *
 * Reference form: #<attr_name>.<field_name>[|min|max|first]
 * - |min   smallest numeric field across selected objects
 * - |max   largest
 * - |first first selected object only (default when suffix omitted)
 *
 * After substitution, arithmetic is evaluated (no arbitrary JavaScript).
 * Rounding: floor(...), ceil(...), round(...)
 * Two-argument: min(a,b), max(a,b) — e.g. min(50,#input_matrix.nber_cols|min)
 *
 * Debug (verbose ref/eval steps): any one of
 *   localStorage.setItem('asap_debug_attr_expressions','1')
 *   window.__ASAP_DEBUG_ATTR_EXPR = true
 *   add ?debug_attrs=1 to the page URL
 * then reload. Filter console by: attrs expr
 * Verbose off: localStorage.removeItem('asap_debug_attr_expressions'); delete window.__ASAP_DEBUG_ATTR_EXPR
 *
 * A normal console line is also printed whenever a default_expression value is actually written to a field (no flag needed).
 */

const DEBUG_LS_KEY = 'asap_debug_attr_expressions'

export function attrExpressionsDebugEnabled() {
  try {
    if (typeof window !== 'undefined' && window.__ASAP_DEBUG_ATTR_EXPR === true) {
      return true
    }
  } catch (_e) {
    /* ignore */
  }
  try {
    if (typeof window !== 'undefined' && window.location && window.location.search) {
      const q = new URLSearchParams(window.location.search)
      if (q.get('debug_attrs') === '1') {
        return true
      }
    }
  } catch (_e) {
    /* ignore */
  }
  try {
    return typeof localStorage !== 'undefined' && localStorage.getItem(DEBUG_LS_KEY) === '1'
  } catch (_e) {
    return false
  }
}

export function attrExpressionsDebugLog(tag, detail) {
  if (!attrExpressionsDebugEnabled()) {
    return
  }
  if (detail !== undefined) {
    console.log('[attrs expr]', tag, detail)
  } else {
    console.log('[attrs expr]', tag)
  }
}

const ROUND_FUNCS = {
  floor: Math.floor,
  ceil: Math.ceil,
  round: Math.round
}

function escapeAttrSelector(value) {
  return String(value || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"')
}

export function parseInputDataHiddenObjects(attrsRoot, attrName) {
  if (!attrsRoot || !attrName) {
    return []
  }
  const escaped = escapeAttrSelector(attrName)
  const container = attrsRoot.querySelector(`[data-attr-name="${escaped}"]`)
  if (!container) {
    return []
  }
  const hidden = container.querySelector('[data-input-data-selector-target="hiddenField"]')
  if (!hidden) {
    return []
  }
  const raw = String(hidden.value || "").trim()
  if (!raw) {
    return []
  }
  try {
    const parsed = JSON.parse(raw)
    if (Array.isArray(parsed)) {
      return parsed.filter((e) => e && typeof e === "object")
    }
    if (parsed && typeof parsed === "object") {
      return [parsed]
    }
  } catch (_e) {
    return []
  }
  return []
}

function aggregateValues(values, mode) {
  const nums = values.filter((n) => Number.isFinite(n))
  if (nums.length === 0) {
    return null
  }
  const agg = mode || "first"
  if (agg === "min") {
    return Math.min(...nums)
  }
  if (agg === "max") {
    return Math.max(...nums)
  }
  return nums[0]
}

export function getSelectionFieldNumeric(attrsRoot, attrName, fieldName, aggregateMode) {
  const objects = parseInputDataHiddenObjects(attrsRoot, attrName)
  if (objects.length === 0) {
    return null
  }
  const rawVals = objects.map((o) => Number(o[fieldName]))
  return aggregateValues(rawVals, aggregateMode || "first")
}

export function substituteAttrSelectionRefs(attrsRoot, expression) {
  if (!attrsRoot || typeof expression !== "string" || expression.trim() === "") {
    return { ok: true, text: expression || "", unresolved: [] }
  }
  const unresolved = []
  const refRe = /#([A-Za-z_][\w]*)\.([A-Za-z_][\w]*)(?:\|(min|max|first))?/g
  const text = expression.replace(refRe, (full, refAttr, refField, agg) => {
    const mode = agg || "first"
    const n = getSelectionFieldNumeric(attrsRoot, refAttr, refField, mode)
    if (attrExpressionsDebugEnabled()) {
      const objs = parseInputDataHiddenObjects(attrsRoot, refAttr)
      attrExpressionsDebugLog("ref", {
        token: full,
        attr: refAttr,
        field: refField,
        aggregate: mode,
        objectCount: objs.length,
        firstObjectDims: objs[0]
          ? { nber_rows: objs[0].nber_rows, nber_cols: objs[0].nber_cols }
          : null,
        numericUsed: n
      })
    }
    if (n === null || !Number.isFinite(n)) {
      unresolved.push(full)
      return full
    }
    return String(n)
  })
  attrExpressionsDebugLog("substitute_done", {
    expression,
    substituted: text,
    unresolved,
    ok: unresolved.length === 0
  })
  return { ok: unresolved.length === 0, text, unresolved }
}

function tokenizeArithmetic(s) {
  const str = String(s || "").replace(/\s+/g, "")
  const tokens = []
  let i = 0
  while (i < str.length) {
    const c = str[i]
    if ("+-*/(),".includes(c)) {
      tokens.push({ op: c })
      i += 1
      continue
    }
    if ((c >= "a" && c <= "z") || (c >= "A" && c <= "Z")) {
      let j = i + 1
      while (
        j < str.length &&
        ((str[j] >= "a" && str[j] <= "z") ||
          (str[j] >= "A" && str[j] <= "Z"))
      ) {
        j += 1
      }
      const word = str.slice(i, j).toLowerCase()
      if (str[j] !== "(") {
        throw new Error("expected ( after " + word)
      }
      if (word === "min" || word === "max") {
        tokens.push({ fnBinary: word })
        tokens.push({ op: "(" })
        i = j + 1
        continue
      }
      if (!ROUND_FUNCS[word]) {
        throw new Error("unknown identifier")
      }
      tokens.push({ fnUnary: word })
      tokens.push({ op: "(" })
      i = j + 1
      continue
    }
    if ((c >= "0" && c <= "9") || c === ".") {
      let j = i + 1
      while (j < str.length && ((str[j] >= "0" && str[j] <= "9") || str[j] === ".")) {
        j += 1
      }
      const num = parseFloat(str.slice(i, j))
      if (!Number.isFinite(num)) {
        throw new Error("invalid number")
      }
      tokens.push({ num })
      i = j
      continue
    }
    throw new Error("invalid character")
  }
  return tokens
}

class ArithParser {
  constructor(tokens) {
    this.tokens = tokens
    this.pos = 0
  }

  peek() {
    return this.tokens[this.pos] || null
  }

  consume(expectedOp) {
    const t = this.peek()
    if (!t || t.op !== expectedOp) {
      throw new Error("parse error")
    }
    this.pos += 1
  }

  parseExpression() {
    let n = this.parseTerm()
    while (this.peek() && (this.peek().op === "+" || this.peek().op === "-")) {
      const op = this.peek().op
      this.pos += 1
      const r = this.parseTerm()
      n = op === "+" ? n + r : n - r
    }
    return n
  }

  parseTerm() {
    let n = this.parseFactor()
    while (this.peek() && (this.peek().op === "*" || this.peek().op === "/")) {
      const op = this.peek().op
      this.pos += 1
      const r = this.parseFactor()
      if (op === "*") {
        n = n * r
      } else {
        if (r === 0) {
          throw new Error("division by zero")
        }
        n = n / r
      }
    }
    return n
  }

  parseFactor() {
    const t = this.peek()
    if (!t) {
      throw new Error("unexpected end")
    }
    if (t.fnBinary) {
      const name = t.fnBinary
      this.pos += 1
      this.consume("(")
      const left = this.parseExpression()
      this.consume(",")
      const right = this.parseExpression()
      this.consume(")")
      return name === "min" ? Math.min(left, right) : Math.max(left, right)
    }
    if (t.fnUnary) {
      const fname = t.fnUnary
      this.pos += 1
      const t2 = this.peek()
      if (!t2 || t2.op !== "(") {
        throw new Error("expected ( after " + fname)
      }
      this.pos += 1
      const inner = this.parseExpression()
      this.consume(")")
      const fn = ROUND_FUNCS[fname]
      if (!fn) {
        throw new Error("unknown function")
      }
      return fn(inner)
    }
    if (t.op === "+") {
      this.pos += 1
      return this.parseFactor()
    }
    if (t.op === "-") {
      this.pos += 1
      return -this.parseFactor()
    }
    if (t.op === "(") {
      this.pos += 1
      const inner = this.parseExpression()
      this.consume(")")
      return inner
    }
    if (t.num !== undefined) {
      this.pos += 1
      return t.num
    }
    throw new Error("unexpected token")
  }
}

export function evaluateArithmeticOnly(expression) {
  const tokens = tokenizeArithmetic(expression)
  if (tokens.length === 0) {
    throw new Error("empty expression")
  }
  const p = new ArithParser(tokens)
  const v = p.parseExpression()
  if (p.pos !== tokens.length) {
    throw new Error("trailing input")
  }
  return v
}

export function evaluateAttrExpression(attrsRoot, expression) {
  const exprIn = typeof expression === "string" ? expression.trim() : ""
  if (!exprIn) {
    const out = { ok: false, value: null, error: "empty", unresolved: [] }
    attrExpressionsDebugLog("evaluate", { expression: exprIn, ...out })
    return out
  }
  const sub = substituteAttrSelectionRefs(attrsRoot, exprIn)
  if (!sub.ok) {
    const out = {
      ok: false,
      value: null,
      error: "unresolved_ref",
      unresolved: sub.unresolved,
      substituted: sub.text
    }
    attrExpressionsDebugLog("evaluate", { expression: exprIn, ...out })
    return out
  }
  if (/#/.test(sub.text)) {
    const out = {
      ok: false,
      value: null,
      error: "leftover_hash",
      unresolved: [],
      substituted: sub.text
    }
    attrExpressionsDebugLog("evaluate", { expression: exprIn, ...out })
    return out
  }
  try {
    const value = evaluateArithmeticOnly(sub.text)
    if (!Number.isFinite(value)) {
      const out = {
        ok: false,
        value: null,
        error: "not_finite",
        substituted: sub.text
      }
      attrExpressionsDebugLog("evaluate", { expression: exprIn, ...out })
      return out
    }
    const out = { ok: true, value, substituted: sub.text }
    attrExpressionsDebugLog("evaluate", { expression: exprIn, ...out })
    return out
  } catch (e) {
    const out = {
      ok: false,
      value: null,
      error: String(e && e.message ? e.message : e),
      substituted: sub.text
    }
    attrExpressionsDebugLog("evaluate", { expression: exprIn, ...out })
    return out
  }
}
