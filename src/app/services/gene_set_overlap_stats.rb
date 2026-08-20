# frozen_string_literal: true

# One-sided Fisher / hypergeometric enrichment helpers for gene-set overlap ranking.
module GeneSetOverlapStats
  module_function

  # Contingency table:
  #   a = overlap
  #   b = gene_set_in_bg - overlap
  #   c = query_in_bg - overlap
  #   d = bg - gene_set_in_bg - query_in_bg + overlap
  # Returns [p_value, odds_ratio]
  def fisher_greater(overlap:, set_in_bg:, query_in_bg:, background_size:)
    a = overlap.to_i
    b = set_in_bg.to_i - a
    c = query_in_bg.to_i - a
    d = background_size.to_i - set_in_bg.to_i - query_in_bg.to_i + a
    return [1.0, 0.0] if [a, b, c, d].any?(&:negative?)
    return [1.0, 0.0] if background_size.to_i <= 0 || query_in_bg.to_i <= 0 || set_in_bg.to_i <= 0

    p = hypergeometric_right_tail(
      k: a,
      n: query_in_bg.to_i,
      k_success: set_in_bg.to_i,
      n_total: background_size.to_i
    )
    odds =
      if b.zero? || c.zero?
        Float::INFINITY
      elsif d.zero?
        0.0
      else
        (a.to_f * d) / (b.to_f * c)
      end
    [p, odds]
  end

  def hypergeometric_right_tail(k:, n:, k_success:, n_total:)
    max_x = [n, k_success].min
    return 1.0 if k <= 0
    return 0.0 if k > max_x
    return 1.0 if n_total <= 0 || n <= 0

    log_probs = (k..max_x).map do |x|
      log_choose(k_success, x) + log_choose(n_total - k_success, n - x) - log_choose(n_total, n)
    end
    log_sum_exp(log_probs)
  end

  def log_choose(n, k)
    return -Float::INFINITY if k.negative? || k > n || n.negative?
    Math.lgamma(n + 1)[0] - Math.lgamma(k + 1)[0] - Math.lgamma(n - k + 1)[0]
  end

  def log_sum_exp(values)
    finite = values.select(&:finite?)
    return 0.0 if finite.empty?
    m = finite.max
    Math.exp(m + Math.log(finite.sum { |v| Math.exp(v - m) }))
  end

  # Benjamini–Hochberg FDR adjustment. Returns array aligned with input p-values.
  def bh_adjust(pvalues)
    m = pvalues.size
    return [] if m.zero?

    order = pvalues.each_with_index.sort_by { |p, _i| p.to_f }.map(&:last)
    adjusted = Array.new(m)
    prev = 1.0
    (m - 1).downto(0) do |rank|
      idx = order[rank]
      val = [1.0, pvalues[idx].to_f * m / (rank + 1)].min
      val = [val, prev].min
      adjusted[idx] = val
      prev = val
    end
    adjusted
  end
end
