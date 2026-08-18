require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_host = ENV['HOST']
    @previous_instance_name = ENV['ASAP_INSTANCE_NAME']
  end

  teardown do
    set_or_delete_env('HOST', @previous_host)
    set_or_delete_env('ASAP_INSTANCE_NAME', @previous_instance_name)
  end

  test "robots.txt blocks all crawlers on the test instance" do
    ENV['HOST'] = 'asap-test.epfl.ch'
    ENV['ASAP_INSTANCE_NAME'] = 'asap_dev'

    get robots_path

    assert_response :success
    assert_equal "text/plain", response.media_type
    assert_equal "User-agent: *\nDisallow: /\n", response.body
    assert_no_match(/Allow:/, response.body)
    assert_no_match(/Sitemap:/, response.body)
    assert_no_match(/Googlebot/, response.body)
  end

  test "robots.txt allows the sitemap and named crawlers on production" do
    ENV['HOST'] = 'asap.epfl.ch'
    ENV['ASAP_INSTANCE_NAME'] = 'asap'

    get robots_path

    assert_response :success
    assert_equal "text/plain", response.media_type

    body = response.body
    assert_match(/^User-agent: \*$/, body)
    assert_match(/^Allow: \/sitemap\.xml$/, body)
    assert_match(/^Disallow: \/$/, body)
    assert_match(/^User-agent: Googlebot$/, body)
    assert_match(/^User-agent: Google-InspectionTool$/, body)
    assert_match(/^User-agent: ClaudeBot$/, body)
    assert_match(/^Allow: \/$/, body)
    assert_match(%r{^Disallow: /annots/\*/download$}, body)
    assert_includes body, "Sitemap: #{ENV.fetch('SERVER_URL').chomp('/')}/sitemap.xml"
  end

  test "sitemap.xml is publicly available" do
    get sitemap_path

    assert_response :success
    assert_equal "application/xml", response.media_type
    assert_includes response.body, '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    assert_includes response.body, "#{ENV.fetch('SERVER_URL').chomp('/')}/"
  end

  private

  def set_or_delete_env(key, value)
    if value.nil?
      ENV.delete(key)
    else
      ENV[key] = value
    end
  end
end
