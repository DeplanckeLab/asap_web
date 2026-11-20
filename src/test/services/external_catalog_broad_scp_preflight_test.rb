# frozen_string_literal: true

require 'test_helper'

# BroadScpCatalog.final_http_status: the SCP download preflight reads only the response headers. Google
# Storage ignores the one-byte Range and sends the whole file, which the preflight must not wait for.
class ExternalCatalogBroadScpPreflightTest < ActiveSupport::TestCase
  # Stands in for curl -D - : prints header blocks, then keeps "transferring" until killed.
  def fake_curl(headers, keep_running: true)
    script = "printf '#{headers}'"
    script += '; sleep 30' if keep_running
    ['sh', '-c', script]
  end

  test 'the first status after the redirects is returned without waiting for the body' do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    code, = ExternalCatalog::BroadScpCatalog.final_http_status(
      fake_curl('HTTP/2 302\r\nlocation: https://storage.example/x\r\n\r\nHTTP/2 200\r\ncontent-type: text/csv\r\n\r\n')
    )
    assert_equal 200, code
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
  end

  test 'a refused download reports its status' do
    code, = ExternalCatalog::BroadScpCatalog.final_http_status(
      fake_curl('HTTP/1.1 302 Found\r\nlocation: x\r\n\r\nHTTP/1.1 403 Forbidden\r\n\r\n', keep_running: false)
    )
    assert_equal 403, code
  end

  test 'no response gives no status and the curl error' do
    code, err = ExternalCatalog::BroadScpCatalog.final_http_status(
      ['sh', '-c', 'echo "curl: (6) Could not resolve host" >&2; exit 6']
    )
    assert_nil code
    assert_match(/Could not resolve host/, err)
  end
end
