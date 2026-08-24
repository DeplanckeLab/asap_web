// Sentinel for "one group vs complementary / rest" on Compared group.
// Submitted as attrs.group_comp; server maps it to "" before CLI (Mode B / null group-2).
export const DE_COMPLEMENTARY_GROUP_VALUE = "__asap_complementary__"
export const DE_COMPLEMENTARY_GROUP_LABEL = "Complementary (all other cells)"

export function isDeComplementaryGroupValue(value) {
  const v = String(value == null ? "" : value).trim()
  return v === DE_COMPLEMENTARY_GROUP_VALUE || v === ""
}
