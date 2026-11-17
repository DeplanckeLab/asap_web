# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

class DockerImageTest < ActiveSupport::TestCase
  test 'fetch_digest_from_docker! prefers matching RepoDigests sha256' do
    payload = {
      'Id' => 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'RepoDigests' => [
        'fabdavid/asap_run@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
      ]
    }

    DockerImage.stub(:inspect_json!, payload) do
      digest = DockerImage.fetch_digest_from_docker!('fabdavid/asap_run:v8')
      assert_equal 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', digest
    end
  end

  test 'fetch_digest_from_docker! uses Id when RepoDigests is empty' do
    payload = {
      'Id' => 'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      'RepoDigests' => []
    }

    DockerImage.stub(:inspect_json!, payload) do
      digest = DockerImage.fetch_digest_from_docker!('fabdavid/asap_run:v8')
      assert_equal 'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc', digest
    end
  end

  test 'fetch_digest_from_docker! raises when no sha256 digest is available' do
    payload = { 'Id' => 'not-a-digest', 'RepoDigests' => [] }

    error = assert_raises(RuntimeError) do
      DockerImage.stub(:inspect_json!, payload) do
        DockerImage.fetch_digest_from_docker!('fabdavid/asap_run:v8')
      end
    end
    assert_match(/No sha256 digest found/, error.message)
  end

  def pin_image(name, runtime_tag)
    image = DockerImage.create!(name: name, tag: 'v8', full_name: "#{name}:v8", runtime_tag: runtime_tag)
    register_for_test_cleanup(image)
    image
  end

  test 'runtime_ref keeps the major tag when the catalog row has no runtime_tag pin' do
    image = pin_image('test/asap_run_unpinned', nil)
    assert_equal 'test/asap_run_unpinned:v8', image.runtime_ref
    assert_equal 'test/asap_run_unpinned:v8', DockerImage.runtime_ref('test/asap_run_unpinned', 'v8')
  end

  test 'runtime_ref resolves a pinned major to its patch tag only' do
    pin_image('test/asap_run_pinned', 'v8.7')
    assert_equal 'test/asap_run_pinned:v8.7', DockerImage.runtime_ref('test/asap_run_pinned', 'v8')
    assert_equal 'test/asap_run_pinned:v8.7',
                 DockerImage.runtime_ref_for('name' => 'test/asap_run_pinned', 'tag' => 'v8')
    assert_equal 'test/asap_run_pinned:v8.3', DockerImage.runtime_ref('test/asap_run_pinned', 'v8.3')
    assert_equal 'test/asap_run_unknown:v8', DockerImage.runtime_ref('test/asap_run_unknown', 'v8')
  end

  test 'runtime_tag must be a patch of the row major tag' do
    image = DockerImage.new(name: 'test/asap_run_bad', tag: 'v8', runtime_tag: 'v8')
    assert_not image.valid?
    image.runtime_tag = 'v7.3'
    assert_not image.valid?
    image.runtime_tag = 'v8.8'
    assert image.valid?
  end

  test 'find_or_create_for_image_ref! files a pinned patch ref under the major catalog row' do
    image = DockerImage.create!(name: 'test/asap_run_pin', tag: 'v8', full_name: 'test/asap_run_pin:v8')
    register_for_test_cleanup(image)
    digest = "sha256:#{SecureRandom.hex(32)}"
    DockerImage.stub(:fetch_digest_from_docker!, digest) do
      build = DockerBuild.find_or_create_for_image_ref!('test/asap_run_pin:v8.7')
      register_for_test_cleanup(build)
      assert_equal image.id, build.docker_image_id
      assert_equal 'v8.7', build.tag
      assert_equal digest, build.digest
    end
  end
end
