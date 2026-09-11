# frozen_string_literal: true

require 'test_helper'

class ApplicationHelperPackageLogoTest < ActionView::TestCase
  tests ApplicationHelper

  test 'method_package_key_from_label reads bracketed package' do
    assert_equal 'scanpy', method_package_key_from_label('UMAP [Scanpy]')
    assert_equal 'seurat', method_package_key_from_label('Leiden [Seurat]')
    assert_equal 'scanpy', method_package_key_from_label('Seurat [Scanpy]')
    assert_nil method_package_key_from_label('Seurat')
    assert_nil method_package_key_from_label(nil)
  end

  test 'tool_version_for_package is case insensitive' do
    tools = { 'scanpy' => '1.12.1', 'Seurat' => '5.5.0' }

    assert_equal '1.12.1', tool_version_for_package(tools, 'scanpy')
    assert_equal '5.5.0', tool_version_for_package(tools, 'seurat')
    assert_nil tool_version_for_package(tools, 'missing')
  end

  test 'package_logo_logical_path prefers versioned png then unversioned' do
    helper = package_logo_helper(
      'seurat.5.png' => true,
      'seurat.png' => true,
      'scanpy.png' => true
    )

    assert_equal 'seurat.5.png', helper.package_logo_logical_path('seurat', '5.5.0')
    assert_equal 'scanpy.png', helper.package_logo_logical_path('scanpy', '1.12.1')
    assert_equal 'seurat.png', helper.package_logo_logical_path('seurat', nil)
    assert_nil helper.package_logo_logical_path('missing', '1.0.0')
  end

  test 'method_package_logo_url resolves from label and tool versions' do
    helper = package_logo_helper('seurat.5.png' => true)
    tools = { 'seurat' => '5.5.0' }

    assert_equal '/assets/seurat.5.png', helper.method_package_logo_url('PCA [Seurat]', tools)
    assert_nil helper.method_package_logo_url('Custom method', tools)
  end

  private

  def package_logo_helper(existing_paths)
    Object.new.tap do |helper|
      helper.extend(ApplicationHelper)
      helper.define_singleton_method(:propshaft_asset_exists?) do |path|
        existing_paths.fetch(path, false)
      end
      helper.define_singleton_method(:asset_path) do |path|
        "/assets/#{path}"
      end
    end
  end
end
