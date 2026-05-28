class AddSourceMethodsFilteringToScalingAndPca < ActiveRecord::Migration[8.0]
  def up
    return unless table_exists?(:steps)
    return unless table_exists?(:docker_images)

    docker_image = DockerImage.find_by(name: 'fabdavid/asap_run', tag: 'v8')
    unless docker_image
      puts "Warning: Docker image 'fabdavid/asap_run:v8' not found. Skipping migration."
      return
    end

    # Update scaling step: exclude seurat_sct from normalization source
    scaling_step = Step.find_by(name: 'scaling', version_id: 8, docker_image_id: docker_image.id)
    if scaling_step
      attrs = JSON.parse(scaling_step.method_attrs_json || '{}')
      if attrs['input_matrix']
        attrs['input_matrix']['excluded_source_methods'] = { 'normalization' => ['seurat_sct'] }
        scaling_step.update!(method_attrs_json: JSON.pretty_generate(attrs))
        puts "Updated scaling step method_attrs_json with excluded_source_methods"
      end
    else
      puts "Warning: scaling step not found for v8"
    end

    # Update pca_sc step: add normalization to source_steps with source_methods filter for SCT only
    pca_step = Step.find_by(name: 'pca_sc', version_id: 8, docker_image_id: docker_image.id)
    if pca_step
      attrs = JSON.parse(pca_step.method_attrs_json || '{}')
      if attrs['input_matrix']
        source_steps = attrs['input_matrix']['source_steps'] || []
        unless source_steps.include?('normalization')
          attrs['input_matrix']['source_steps'] = source_steps + ['normalization']
        end
        attrs['input_matrix']['source_methods'] = { 'normalization' => ['seurat_sct'] }
        pca_step.update!(method_attrs_json: JSON.pretty_generate(attrs))
        puts "Updated pca_sc step method_attrs_json with source_methods and added normalization to source_steps"
      end
    else
      puts "Warning: pca_sc step not found for v8"
    end
  end

  def down
    return unless table_exists?(:steps)
    return unless table_exists?(:docker_images)

    docker_image = DockerImage.find_by(name: 'fabdavid/asap_run', tag: 'v8')
    return unless docker_image

    # Revert scaling step
    scaling_step = Step.find_by(name: 'scaling', version_id: 8, docker_image_id: docker_image.id)
    if scaling_step
      attrs = JSON.parse(scaling_step.method_attrs_json || '{}')
      if attrs['input_matrix']
        attrs['input_matrix'].delete('excluded_source_methods')
        scaling_step.update!(method_attrs_json: JSON.pretty_generate(attrs))
      end
    end

    # Revert pca_sc step
    pca_step = Step.find_by(name: 'pca_sc', version_id: 8, docker_image_id: docker_image.id)
    if pca_step
      attrs = JSON.parse(pca_step.method_attrs_json || '{}')
      if attrs['input_matrix']
        attrs['input_matrix']['source_steps']&.delete('normalization')
        attrs['input_matrix'].delete('source_methods')
        pca_step.update!(method_attrs_json: JSON.pretty_generate(attrs))
      end
    end
  end
end
