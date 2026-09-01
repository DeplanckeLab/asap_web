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

  test "robots.txt allows all crawlers on production except annot downloads" do
    ENV['HOST'] = 'asap.epfl.ch'
    ENV['ASAP_INSTANCE_NAME'] = 'asap'

    get robots_path

    assert_response :success
    assert_equal "text/plain", response.media_type

    body = response.body
    assert_equal <<~ROBOTS, body
      User-agent: *
      Allow: /
      Disallow: /annots/*/download

      Sitemap: #{ENV.fetch('SERVER_URL').chomp('/')}/sitemap.xml
    ROBOTS
  end

  test "sitemap.xml is publicly available" do
    get sitemap_path

    assert_response :success
    assert_equal "application/xml", response.media_type
    assert_includes response.body, '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    assert_includes response.body, "#{ENV.fetch('SERVER_URL').chomp('/')}/"
  end

  test "unauthorized page returns 403 with noindex" do
    get unauthorized_path

    assert_response :forbidden
    assert_match(/noindex/, response.body)
    assert_match(/Cannot access this page/, response.body)
  end

  test "api-doc forces a full page load so Swagger UI can boot" do
    host! ENV.fetch("HOST", "www.example.com")

    get api_doc_path

    assert_response :success
    assert_includes response.body, 'name="turbo-visit-control" content="reload"'
    assert_includes response.body, 'name="turbo-cache-control" content="no-cache"'
    assert_includes response.body, 'id="swagger-ui"'
    assert_includes response.body, "SwaggerUIBundle"
  end

  test "openapi spec uses instance HOST for server URL and examples" do
    ENV['HOST'] = 'asap.epfl.ch'
    host! 'asap.epfl.ch'

    get '/api/openapi.yaml'

    assert_response :success
    assert_equal 'application/yaml', response.media_type
    assert_includes response.body, 'url: https://asap.epfl.ch/api'
    assert_includes response.body, 'GET https://asap.epfl.ch/api/projects'
    refute_includes response.body, 'asap-test.epfl.ch'
    refute_includes response.body, '__ASAP_API_BASE__'
  end

  test "openapi spec on test instance uses asap-test host in examples" do
    ENV['HOST'] = 'asap-test.epfl.ch'
    host! 'asap-test.epfl.ch'

    get '/api/openapi.yaml'

    assert_response :success
    assert_includes response.body, 'url: https://asap-test.epfl.ch/api'
    assert_includes response.body, 'GET https://asap-test.epfl.ch/api/compliance/checks'
    refute_includes response.body, '__ASAP_API_BASE__'
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
