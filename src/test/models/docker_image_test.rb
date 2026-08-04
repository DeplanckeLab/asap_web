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

    DockerImage.stub(:docker_image_inspect_json!, payload) do
      digest = DockerImage.fetch_digest_from_docker!('fabdavid/asap_run:v8')
      assert_equal 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', digest
    end
  end

  test 'fetch_digest_from_docker! uses Id when RepoDigests is empty' do
    payload = {
      'Id' => 'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      'RepoDigests' => []
    }

    DockerImage.stub(:docker_image_inspect_json!, payload) do
      digest = DockerImage.fetch_digest_from_docker!('fabdavid/asap_run:v8')
      assert_equal 'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc', digest
    end
  end

  test 'fetch_digest_from_docker! raises when no sha256 digest is available' do
    payload = { 'Id' => 'not-a-digest', 'RepoDigests' => [] }

    error = assert_raises(RuntimeError) do
      DockerImage.stub(:docker_image_inspect_json!, payload) do
        DockerImage.fetch_digest_from_docker!('fabdavid/asap_run:v8')
      end
    end
    assert_match(/No sha256 digest found/, error.message)
  end
end
