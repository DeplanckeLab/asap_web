require 'cgi'
require 'zlib'

module Basic

  # Cla rows created by parsing / load_annot (add_clas) use this cla_sources.id (ASAP auto annotation).
  ASAP_AUTO_CLA_SOURCE_ID = 3
  # Manual annotations submitted from the visualization annotation popup.
  MANUAL_CLA_SOURCE_ID = 1

  # Suggested embedded JSON key for the cross-tool metadata catalog (location depends on file format: LOOM attrs, H5AD, RDS, etc.).
  DATA_FILE_METADATA_CATALOG_ATTR = 'metadata_catalog'
  DATA_FILE_METADATA_CATALOG_SCHEMA_VERSION = '1'
  DATA_FILE_METADATA_CATALOG_TOOL_ASAP = 'ASAP'
  DATA_FILE_TYPES = %w[LOOM H5AD RDS].freeze
  DATA_FILE_TYPE_BY_EXTENSION = {
    '.loom' => 'LOOM',
    '.h5ad' => 'H5AD',
    '.rds' => 'RDS'
  }.freeze
  INTEGRATION_METHODS = %w[harmony cca rpca uncorrected].freeze
  INTEGRATION_METHOD_LABELS = {
    'harmony' => 'Harmony',
    'cca' => 'CCA',
    'rpca' => 'RPCA',
    'uncorrected' => 'Uncorrected'
  }.freeze

  # Raised when a cloned project needs the same metadata column on the immediate parent project
  # (see marker_groups_annot_id) and that source Annot row cannot be found.
  SourceAnnotResolutionError = Class.new(StandardError)

  #class Basic

  class << self

    def asap_data_db_name_from_env!(h_env)
      db_name = if ENV["ASAP2_REMOTE_DB"].present?
                  ENV["ASAP2_REMOTE_DB"].to_s.strip
                else
                  h_env['asap_data_db_name'].to_s.strip
                end
      raise ArgumentError, "Missing asap_data_db_name in version env_json" if db_name.empty?

      db_name
    end

    def asap_data_db_url(h_env)
      host = ENV.fetch("ASAP2_REMOTE_HOST", "host.docker.internal")
      port = ENV.fetch("ASAP2_REMOTE_PORT", 5433).to_s
      "#{host}:#{port}/#{asap_data_db_name_from_env!(h_env)}"
    end

    def project_export_server_url
      ENV.fetch('SERVER_URL').to_s.chomp('/')
    end

    def normalize_data_file_path(path)
      path.to_s.strip.sub(%r{\A/+}, '')
    end

    def data_file_type_from_path(path)
      DATA_FILE_TYPE_BY_EXTENSION[File.extname(path.to_s).downcase]
    end

    def data_file_url_for_project(project, data_file_path)
      "#{project_export_server_url}/projects/#{project.key}/get_file?filename=#{CGI.escape(data_file_path)}"
    end

    # Docker Hub image layers URL.
    # With digest: https://hub.docker.com/layers/fabdavid/asap_run/v8/images/sha256-56e75aeb...
    # Without:     https://hub.docker.com/layers/fabdavid/asap_run/v8
    def dockerhub_layers_url(image_name, digest: nil)
      return nil if image_name.blank?

      image_ref = image_name.to_s.strip.split('@').first
      repo, tag = if image_ref.include?(':')
        image_ref.rpartition(':').values_at(0, 2)
      else
        [image_ref, 'latest']
      end
      return nil if repo.blank? || repo.include?(' ') || repo.include?('://')
      return nil unless repo.match?(%r{\A[a-z0-9][a-z0-9_.-]*/[a-z0-9][a-z0-9_.-]+(?:/[a-z0-9][a-z0-9_.-]+)?\z}i)

      url = "https://hub.docker.com/layers/#{repo}/#{tag}"
      digest_s = digest.to_s.strip
      return url if digest_s.blank?

      digest_path = digest_s.sub(/\Asha256:/i, 'sha256-')
      digest_path = "sha256-#{digest_path}" unless digest_path.start_with?('sha256-')
      "#{url}/images/#{digest_path}"
    end

    def build_export_lookup_tables
      h_references = {}
      Article.all.each { |a| h_references[a.doi] = a }
      h_organisms = {}
      Organism.all.each { |e| h_organisms[e.id] = e }
      h_identifier_types = {}
      IdentifierType.all.each { |it| h_identifier_types[it.id] = it }
      h_cla_sources = {}
      ClaSource.all.each { |cla_source| h_cla_sources[cla_source.id] = cla_source }
      h_cell_ontologies = {}
      CellOntology.all.each { |co| h_cell_ontologies[co.id] = co }
      h_envs = {}
      Version.all.each { |v| h_envs[v.id] = Basic.safe_parse_json(v.env_json, {}) }
      h_steps = {}
      Step.all.each { |s| h_steps[s.id] = s }
      h_std_methods = {}
      StdMethod.all.each { |s| h_std_methods[s.id] = s }
      h_project_types = {}
      ProjectType.all.each { |e| h_project_types[e.id] = e }
      {
        :h_references => h_references,
        :h_organisms => h_organisms,
        :h_identifier_types => h_identifier_types,
        :h_cla_sources => h_cla_sources,
        :h_cell_ontologies => h_cell_ontologies,
        :h_envs => h_envs,
        :h_steps => h_steps,
        :h_std_methods => h_std_methods,
        :h_project_types => h_project_types
      }
    end

    def project_export_context_for_metadata(p, tables)
      server_url = project_export_server_url
      h_references = tables[:h_references]
      h_organisms = tables[:h_organisms]
      h_identifier_types = tables[:h_identifier_types]
      h_project_types = tables[:h_project_types]
      {
        :public_key => p.public_key,
        :key => p.key,
        :url => "#{server_url}/projects/#{p.key}",
        :json_url => "#{server_url}/api/projects/#{p.key}",
        :doi => p.doi,
        :version => "v" + p.version_id.to_s,
        :nber_cols => p.nber_cols,
        :nber_rows => p.nber_rows,
        :reference => h_references[p.doi],
        :tissue => p.tissue,
        :technology => p.technology,
        :extra_info => p.extra_info,
        :tax_id => h_organisms[p.organism_id].tax_id,
        :organism => h_organisms[p.organism_id].name,
        :cloned_project_id => p.cloned_project_id,
        :project_type => (h_project_types[p.project_type_id]) ? h_project_types[p.project_type_id].name : nil,
        :experiments => p.exp_entries.map { |e|
          {
            :identifier_type => h_identifier_types[e.identifier_type_id].name,
            :identifier => e.identifier,
            :url => h_identifier_types[e.identifier_type_id].url_mask.gsub(/\#\{id\}/, e.identifier)
          }
        }
      }
    end

    def build_cla_export_hash(e, h_env, tables)
      h_cell_ontologies = tables[:h_cell_ontologies]
      h_cla_sources = tables[:h_cla_sources]

      up_genes = (e.up_gene_ids and e.up_gene_ids.size > 0) ? Basic.sql_query2(:asap_data, h_env['asap_data_db_version'], 'genes', '', '*', "id in (#{e.up_gene_ids})").map { |g| Basic.format_gene(g) } : nil
      down_genes = (e.down_gene_ids and e.down_gene_ids.size > 0) ? Basic.sql_query2(:asap_data, h_env['asap_data_db_version'], 'genes', '', '*', "id in (#{e.down_gene_ids})").map { |g| Basic.format_gene(g) } : nil

      cots = (e.cell_ontology_term_ids) ?
        ::CellOntologyTerm.where(:id => e.cell_ontology_term_ids.split(",")).all.map { |cot|
          {
            :identifier => cot.identifier,
            :name => cot.name,
            :description => cot.description,
            :ontology => h_cell_ontologies[cot.cell_ontology_id].name
          }
        } : nil

      {
        :id => e.id,
        :num => e.num,
        :name => e.name,
        :cell_set_key => (cs = e.cell_set) ? cs.key : nil,
        :comment => e.comment,
        :project_id => e.project_id,
        :clone_id => e.clone_id,
        :cat => e.cat,
        :cat_idx => e.cat_idx,
        :cell_ontology_terms => cots || [],
        :up_genes => up_genes,
        :down_genes => down_genes,
        :orcid_user => OrcidUser.where(:id => e.orcid_user_id).first,
        :user_id => (u = User.where(:id => e.user_id).first) ? u.email : nil,
        :source => (e.cla_source_id and h_cla_sources[e.cla_source_id]) ? h_cla_sources[e.cla_source_id].name : nil,
        :nber_agree => e.nber_agree,
        :nber_disagree => e.nber_disagree,
        :score => e.nber_agree - e.nber_disagree,
        :obsolete => e.obsolete,
        :created_at => e.created_at,
        :updated_at => e.updated_at
      }
    end

    def build_clas_index_for_project(p, tables, data_file_path: nil)
      h_env = tables[:h_envs][p.version_id]
      h_annots = {}
      h_clas = {}
      cla_scope = Cla.where(:project_id => p.id)
      if data_file_path.present?
        annot_ids = Annot.where(:project_id => p.id, :filepath => data_file_path).pluck(:id)
        cla_scope = cla_scope.where(:annot_id => annot_ids)
      end
      cla_scope.find_each do |e|
        cla = build_cla_export_hash(e, h_env, tables)
        h_annots[e.annot_id] = {}
        h_clas[e.annot_id] ||= []
        h_clas[e.annot_id].push cla
      end
      Annot.where(:id => h_annots.keys).all.each { |a| h_annots[a.id] = a }
      { :h_annots => h_annots, :h_clas => h_clas }
    end

    def sanitize_export_command_paths(command, project, project_dir)
      return command if command.blank?

      user_id = project.user_id.to_s
      project_key = project.key.to_s
      user_data_dir = ENV.fetch('USER_DATA_DIR').to_s.chomp('/')
      data_roots = [
        Pathname.new(user_data_dir).parent.to_s,
        user_data_dir,
        '/data/asap2',
        '/data/asap2_test'
      ].map { |root| root.to_s.chomp('/') }.uniq

      prefixes = [project_dir.to_s.chomp('/')]
      data_roots.each do |root|
        prefixes << "#{root}/users/#{user_id}/#{project_key}"
        prefixes << "#{root}/#{user_id}/#{project_key}"
      end

      cmd = command.dup
      prefixes.uniq.reject(&:blank?).sort_by { |path| -path.length }.each do |prefix|
        cmd = cmd.gsub(prefix, '$PROJECT_DIR')
      end
      cmd
    end

    def build_run_pipeline_for_annot(annot, project, project_dir, tables, asap_data_db)
      h_steps = tables[:h_steps]
      h_std_methods = tables[:h_std_methods]
      run = Run.where(:id => annot.run_id).first
      return [] unless run

      lineage_runs = Run.where(:id => run.lineage_run_ids.split(",")).all + [run]
      h_command = Basic.safe_parse_json(run.command_json, {})
      command = Basic.build_cmd(h_command)
      command = sanitize_export_command_paths(command, project, project_dir)
      command = command.gsub(/postgres\:\d+\/asap_data_v\d+/, ('$ASAP_DATA_DB_HOST:$ASAP_DATA_DB_PORT/' + asap_data_db))
      docker_image_name = ""
      if h_command['docker_call'] and m = h_command['docker_call'].match(/([\w\d\:\/]+) -c$/)
        docker_image_name = m[1]
      end
      docker_image_url = dockerhub_layers_url(docker_image_name)
      lineage_runs.map { |e|
        {
          :run_id => e.id,
          :step_id => e.step_id,
          :step_label => h_steps[e.step_id].label,
          :method_id => e.std_method_id,
          :method_label => h_std_methods[e.std_method_id].label,
          :num => e.num,
          :attrs => Basic.safe_parse_json(e.attrs_json, {}),
          :command => ((h_steps[e.step_id].name != 'parsing') ? command : nil),
          :docker_repo => "dockerhub",
          :docker_image_url => docker_image_url,
          :docker_image_name => docker_image_name
        }
      }
    end

    def build_metadata_list_entries(p, index, project_dir, tables, asap_data_db, data_file_path: nil)
      h_clas = index[:h_clas]
      metadata_lists = []
      annots_scope = Annot.where(:project_id => p.id, :dim => 1)
      annots_scope = annots_scope.where(:filepath => data_file_path) if data_file_path.present?
      annots_scope.order(:name).find_each do |annot|
        metadata_id = annot.id
        metadata_lists.push(
          :run_pipeline => build_run_pipeline_for_annot(annot, p, project_dir, tables, asap_data_db),
          :id => annot.id,
          :run_id => annot.run_id,
          :path => annot.name,
          :annotations => (h_clas[metadata_id] || []).select { |e| e[:num] and e[:score] }.sort { |a, b| [b[:score], a[:num]] <=> [a[:score], b[:num]] }
        )
      end
      metadata_lists
    end

    def append_ontology_terms_to_project_export!(h, p, h_annots)
      h_cots = {}
      ::CellOntologyTerm.where(:id => OtProject.where(:project_id => p.id).all.map { |e| e.cell_ontology_term_id }.uniq).all.each do |cot|
        h_cots[cot.id] = cot
      end

      OntologyTermType.all.each do |ott|
        ott_key = ott.name
        ot_projects = OtProject.where(:ontology_term_type_id => ott.id, :project_id => p.id).all
        ott_project = OttProject.where(:ontology_term_type_id => ott.id, :project_id => p.id).first
        if ott_project and ott_project.not_applicable
          h[ott_key] = nil
        else
          h[ott_key] = ot_projects.map { |otp|
            {
              :identifier => (cot_id = otp.cell_ontology_term_id) ? h_cots[cot_id].identifier : nil,
              :name => (cot_id) ? h_cots[cot_id].name : otp.free_text,
              :from_metadata => (otp.annot_id and h_annots[otp.annot_id]) ? h_annots[otp.annot_id].name : nil
            }
          }
        end
      end
      h
    end

    def generate_project_json p
      tables = build_export_lookup_tables
      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + p.user_id.to_s + p.key
      h_env = tables[:h_envs][p.version_id]
      asap_data_db = Basic.asap_data_db_name_from_env!(h_env)
      index = build_clas_index_for_project(p, tables)
      metadata_lists = build_metadata_list_entries(p, index, project_dir, tables, asap_data_db)
      annots_by_id = Annot.where(:project_id => p.id).index_by(&:id)
      server_url = project_export_server_url
      h = {
        :public_key => p.public_key,
        :key => p.key,
        :url => "#{server_url}/projects/#{p.key}",
        :json_url => "#{server_url}/api/projects/#{p.key}",
        :doi => p.doi,
        :asap_data_db => asap_data_db,
        :asap_data_db_url => ENV.fetch('SERVER_URL') + "/dumps/#{asap_data_db}.sql.gz",
        :version => "v" + p.version_id.to_s,
        :reproducibility_instructions_url => ENV.fetch('SERVER_URL') + "/projects/#{p.key}/instructions",
        :reproducibility_script_url => ENV.fetch('SERVER_URL') + "/projects/#{p.key}/get_commands",
        :nber_cols => p.nber_cols,
        :nber_rows => p.nber_rows,
        :reference => tables[:h_references][p.doi],
        :tissue => p.tissue,
        :technology => p.technology,
        :extra_info => p.extra_info,
        :tax_id => tables[:h_organisms][p.organism_id].tax_id,
        :organism => tables[:h_organisms][p.organism_id].name,
        :cloned_project_id => p.cloned_project_id,
        :project_type => (tables[:h_project_types][p.project_type_id]) ? tables[:h_project_types][p.project_type_id].name : nil,
        :nber_cloned => p.nber_cloned,
        :nber_views => p.nber_views,
        :disk_size_archived => p.disk_size_archived,
        :project_cell_set_key => (pcs = p.project_cell_set) ? pcs.key : nil,
        :experiments => p.exp_entries.map { |e|
          {
            :identifier_type => tables[:h_identifier_types][e.identifier_type_id].name,
            :identifier => e.identifier,
            :url => tables[:h_identifier_types][e.identifier_type_id].url_mask.gsub(/\#\{id\}/, e.identifier)
          }
        },
        :metadata_lists => metadata_lists
      }
      append_ontology_terms_to_project_export!(h, p, annots_by_id)
    end

    # Cross-tool metadata catalog for one project data file (LOOM, H5AD, RDS, etc.).
    # Persisted location is format-specific; see DATA_FILE_METADATA_CATALOG_ATTR.
    def generate_data_file_metadata_catalog(p, data_file_path)
      data_file_path = normalize_data_file_path(data_file_path)
      return nil if data_file_path.blank?
      return nil unless Annot.where(:project_id => p.id, :filepath => data_file_path).exists?

      data_file_type = data_file_type_from_path(data_file_path)
      return nil unless data_file_type

      tables = build_export_lookup_tables
      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + p.user_id.to_s + p.key
      h_env = tables[:h_envs][p.version_id]
      asap_data_db = Basic.asap_data_db_name_from_env!(h_env)
      index = build_clas_index_for_project(p, tables, :data_file_path => data_file_path)
      project_ctx = project_export_context_for_metadata(p, tables)
      lists = build_metadata_list_entries(p, index, project_dir, tables, asap_data_db, data_file_path: data_file_path)

      list_of_projects = [
        {
          :tool => DATA_FILE_METADATA_CATALOG_TOOL_ASAP,
          :identifier => p.key,
          :url => project_ctx[:url],
          :json_url => project_ctx[:json_url]
        }
      ]

      run_entries_by_id = {}
      lists.each do |entry|
        Array(entry[:run_pipeline]).each do |run_entry|
          run_id = run_entry[:run_id].to_i
          next unless run_id.positive?
          run_entries_by_id[run_id] ||= run_entry
        end
      end
      run_created_at_by_id = Run.where(:id => run_entries_by_id.keys).pluck(:id, :created_at).to_h
      sorted_run_ids = run_entries_by_id.keys.sort_by { |rid| [run_created_at_by_id[rid] || Time.at(0), rid] }

      list_of_runs = []
      run_idx_by_id = {}
      sorted_run_ids.each_with_index do |rid, idx|
        run_idx_by_id[rid] = idx
        list_of_runs << run_entries_by_id[rid].merge(:project_idx => 0)
      end

      list_of_metadata = lists.map do |entry|
        pipeline_run_idx = Array(entry[:run_pipeline]).map { |run_entry|
          rid = run_entry[:run_id].to_i
          run_idx_by_id[rid]
        }.compact
        entry.except(:run_pipeline).merge(:pipeline_run_idx => pipeline_run_idx)
      end

      {
        :schema_version => DATA_FILE_METADATA_CATALOG_SCHEMA_VERSION,
        :data_file_url => data_file_url_for_project(p, data_file_path),
        :data_file_type => data_file_type,
        :list_of_projects => list_of_projects,
        :list_of_runs => list_of_runs,
        :list_of_metadata => list_of_metadata
      }
    end

      def format_gene g

    return {
      :name => g['name'],
      :ensembl_id => g['ensembl_id'],
      :biotype => g['biotype'],
      :chr => g['chr'],
      :ncbi_gene_id => g['ncbi_gene_id'],
      :latest_ensembl_release => g['latest_ensembl_release'],
      :description => g['description'],
      :function_description => g['function_description'],
      :alt_names => g['alt_names']
    }

  end


    def upd_project_cell_set p

      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + p.user_id.to_s + p.key
      loom_path = project_dir + 'parsing' + 'output.loom'
      return unless File.exist?(loom_path)

      puts "get cells..."
      cells = H5DataService.get_metadata_vector(loom_path.to_s, '/col_attrs/CellID')
      if cells.blank?
        cmd = "java -jar #{ENV.fetch('LOCAL_ASAP_RUN_DIR')}/ASAP.jar -T ExtractMetadata -loom #{loom_path} -meta /col_attrs/CellID"
        output = `#{cmd}`
        File.open(project_dir + 'parsing' + 'cell_ids', 'w') do |fout|
          fout.write(output)
        end
        res = Basic.safe_parse_json(output, {})
        cells = res['values']
      else
        File.open(project_dir + 'parsing' + 'cell_ids', 'w') do |fout|
          fout.write({ 'values' => cells }.to_json)
        end
      end

      if cells and cells.size > 0

        dataset_md5 = Digest::MD5.hexdigest({:cells => cells.sort}.to_json)

        pc = ProjectCellSet.where(:key => dataset_md5).first
        if !pc
          pc = ProjectCellSet.new(:key => dataset_md5, :nber_cells => cells.size)
          pc.save
        else
          pc.update({:nber_cells => cells.size})
        end

        p.update({:project_cell_set_id => pc.id})

      end
    end

    # Ensure AnnotCellSet / CellSet rows exist for a discrete cell metadata annot.
    # Used by manual CLA creation when finish_run never populated cell sets for this project/annot.
    def ensure_annot_cell_sets(project, annot, logger: nil)
      return {} unless project && annot
      return {} unless annot.dim.to_i == 1 && annot.data_type_id.to_i == 3

      list_cats = safe_parse_json(annot.list_cat_json, [])
      return {} if list_cats.blank?

      existing = AnnotCellSet.where(annot_id: annot.id).index_by(&:cat_idx)
      if list_cats.each_index.all? { |i| existing[i]&.cell_set_id.present? }
        return existing.transform_values { |acs| CellSet.find_by(id: acs.cell_set_id) }.compact
      end

      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
      loom_path = project_dir + annot.filepath
      unless File.exist?(loom_path)
        logger&.error("[ensure_annot_cell_sets] loom not found: #{loom_path}")
        return {}
      end

      unless project.project_cell_set_id.present? && File.exist?(project_dir + 'parsing' + 'cell_ids')
        upd_project_cell_set(project)
        project.reload
      end
      unless project.project_cell_set_id.present?
        logger&.error("[ensure_annot_cell_sets] project #{project.id} has no project_cell_set")
        return {}
      end

      stable_ids_file = project_dir + (annot.filepath.to_s + '.stable_ids')
      unless File.exist?(stable_ids_file)
        stable_ids = H5DataService.get_metadata_vector(loom_path.to_s, '/col_attrs/_StableID')
        if stable_ids.present?
          File.open(stable_ids_file, 'w') { |fout| fout.write({ 'values' => stable_ids }.to_json) }
        else
          logger&.error("[ensure_annot_cell_sets] could not extract _StableID for #{annot.id}")
          return {}
        end
      end

      meta_compl = H5DataService.extract_metadata_compl(
        loom_path.to_s,
        annot.name,
        type_name: 'DISCRETE',
        no_values: false
      )
      if meta_compl['values'].blank?
        values = H5DataService.get_metadata_vector(loom_path.to_s, annot.name)
        meta_compl = { 'values' => values } if values.present?
      end
      if meta_compl['values'].blank?
        logger&.error("[ensure_annot_cell_sets] could not extract values for annot #{annot.id} #{annot.name}")
        return {}
      end

      cache = { cell_sets_by_md5: {}, annot_cell_sets_by_project_id: {} }
      CellSet.where(project_cell_set_id: project.project_cell_set_id).find_each do |cs|
        cache[:cell_sets_by_md5][cs.key] = cs
      end
      AnnotCellSet.where(project_id: project.id).find_each do |acs|
        cache[:annot_cell_sets_by_project_id][project.id] ||= {}
        cache[:annot_cell_sets_by_project_id][project.id][[acs.annot_id, acs.cat_idx]] = acs
      end

      add_cell_sets(project, project_dir, annot, meta_compl, list_cats, cache)
    end
    
    def get_s3_settings
      if ENV['S3_SETTINGS_JSON'].present?
        return JSON.parse(ENV['S3_SETTINGS_JSON'])
      end

      candidate_files = []
      candidate_files << ENV['S3_SETTINGS_FILE'] if ENV['S3_SETTINGS_FILE'].present?
      candidate_files << (Pathname.new(Rails.root) + 'config' + '.s3.json').to_s
      candidate_files << '/srv/asap2_2026_03_09/config/.s3.json'

      settings_file = candidate_files.compact.find { |path| File.exist?(path) }
      raise "S3 settings file not found. Checked: #{candidate_files.compact.join(', ')}" unless settings_file

      JSON.parse(File.read(settings_file))
    end
    
    
    def connect_s3 s3b, h_s3_settings
      Aws.config.update({
                          :endpoint => s3b[:endpoint],
                          :region => s3b[:region],
                          :access_key_id => h_s3_settings[s3b[:key]]["rw"][0],
                          :secret_access_key => h_s3_settings[s3b[:key]]["rw"][1]
                        })
      return Aws::S3::Client.new
    end
    
    def connect_resource_s3 s3b, h_s3_settings ### for upload on S3                                                                                                 
      Aws.config.update({
                          :endpoint => s3b[:endpoint],
                          :region => s3b[:region],
                          :access_key_id => h_s3_settings[s3b[:key]]["rw"][0],
                          :secret_access_key => h_s3_settings[s3b[:key]]["rw"][1]
                        })
      return Aws::S3::Resource.new
    end
    
    
    def write_file_from_s3 s3, bucket_id, project, filepath
      parent_dir = File.dirname(filepath.to_s)
      FileUtils.mkdir_p(parent_dir) unless File.exist?(parent_dir)

      begin
        head = s3.head_object(bucket: bucket_id, key: project.key)
        puts "METADATA: " + head.metadata.to_json

        content_length = head.content_length.to_i
        return false if content_length <= 0

        # Use concurrent ranged GET requests for faster retrieval.
        thread_count = ENV.fetch('S3_DOWNLOAD_THREADS', '16').to_i
        thread_count = 1 if thread_count < 1
        thread_count = 64 if thread_count > 64
        chunk_size_mb = ENV.fetch('S3_DOWNLOAD_CHUNK_MB', '16').to_i
        chunk_size_mb = 5 if chunk_size_mb < 5
        chunk_size = chunk_size_mb * 1024 * 1024

        File.open(filepath.to_s, 'wb') { |f| f.truncate(content_length) }

        ranges = Queue.new
        start_byte = 0
        while start_byte < content_length
          end_byte = [start_byte + chunk_size - 1, content_length - 1].min
          ranges << [start_byte, end_byte]
          start_byte = end_byte + 1
        end

        workers = [thread_count, ranges.size].min
        threads = workers.times.map do
          Thread.new do
            loop do
              begin
                range_start, range_end = ranges.pop(true)
              rescue ThreadError
                break
              end

              response = s3.get_object(
                bucket: bucket_id,
                key: project.key,
                range: "bytes=#{range_start}-#{range_end}"
              )
              chunk = response.body.read

              File.open(filepath.to_s, 'rb+') do |f|
                f.seek(range_start)
                f.write(chunk)
              end
            end
          end
        end
        threads.each(&:join)

        File.exist?(filepath) && File.size(filepath).to_i == content_length
      rescue => e
        Rails.logger.error("[Basic.write_file_from_s3] #{e.class}: #{e.message}")
        false
      end
    end
    
    def write_file_on_s3 s3b, filepath, metadata
      h_s3_settings = get_s3_settings()
      client = connect_s3(s3b, h_s3_settings)
      key = metadata.delete(:key)
      upload_thread_count = ENV.fetch('S3_UPLOAD_THREADS', '16').to_i
      upload_thread_count = 1 if upload_thread_count < 1
      upload_thread_count = 64 if upload_thread_count > 64
      upload_multipart_threshold_mb = ENV.fetch('S3_UPLOAD_MULTIPART_THRESHOLD_MB', '16').to_i
      upload_multipart_threshold_mb = 5 if upload_multipart_threshold_mb < 5
      upload_multipart_threshold_bytes = upload_multipart_threshold_mb * 1024 * 1024
      puts "Writing on S3"
      begin
        transfer_manager = Aws::S3::TransferManager.new(client: client)
        upload_ok = transfer_manager.upload_file(
          filepath.to_s,
          bucket: s3b[:key],
          key: key,
          thread_count: upload_thread_count,
          multipart_threshold: upload_multipart_threshold_bytes,
          metadata: metadata
        )
        raise "S3 TransferManager upload returned false for key=#{key}" unless upload_ok

        bucket = connect_resource_s3(s3b, h_s3_settings).bucket(s3b[:key])
        return bucket.object(key)
      rescue StandardError => e
        Rails.logger.error("[Basic.write_file_on_s3] key=#{key} error=#{e.class} #{e.message}")
        return nil
      end
      
    end

    def get_asap_docker version
      return nil if version.nil?

      raw = version.env_json
      return nil if raw.blank?

      h_env = JSON.parse(raw)
      unless h_env.is_a?(Hash)
        return nil
      end

      docker_cfgs = h_env['docker_images']
      return nil unless docker_cfgs.is_a?(Hash)

      list_docker_image_names = docker_cfgs.filter_map do |_key, cfg|
        next unless cfg.is_a?(Hash)

        n = cfg['name'].to_s
        next if n.empty?

        "#{n}:#{cfg['tag']}"
      end
      return nil if list_docker_image_names.empty?

      docker_images = DockerImage.where(full_name: list_docker_image_names).to_a
      asap_docker_name = ENV.fetch('ASAP_DOCKER_NAME')
      docker_images.find { |e| e.name == asap_docker_name }
    rescue JSON::ParserError, TypeError
      nil
    end

    # Mounted host:container at the same absolute path (typical Linux deploy).
    def prediction_data_root_mount
      ENV.fetch('PROD_DATA_DIR')
    end

    # Directory containing version subfolders, passed to prediction.tool.2.R (first path argument).
    def prediction_models_path_for_r
      File.join(prediction_data_root_mount, 'pred_models')
    end

    def prediction_docker_volume_mount_arg
      r = prediction_data_root_mount
      "-v #{r}:#{r}"
    end

    # Mount argument (-v host:container) that makes project data (USER_DATA_DIR
    # and sibling upload dirs like UPLOAD_DATA_DIR) reachable from sibling
    # docker containers spawned via DOCKER_CALL. Uses the parent of USER_DATA_DIR
    # so that both users/ and fus/ subtrees are visible under the same path.
    def user_data_docker_volume_mount_arg
      user_data_root = Pathname.new(ENV.fetch('USER_DATA_DIR')).parent.to_s
      "-v #{user_data_root}:#{user_data_root}"
    end

    # Host path to .env_asap_run (sibling of USER_DATA_DIR users/ and fus/ dirs).
    def asap_run_env_file_path
      Pathname.new(ENV.fetch('USER_DATA_DIR')).parent.join('.env_asap_run').to_s
    end

    # Optional docker --env-file fragment for asap_run containers.
    # Trailing space keeps glued legacy templates (#env_file_option#image_name) valid.
    def asap_run_env_file_docker_option
      "--env-file #{asap_run_env_file_path} "
    end

    # Canonical docker run prefix stored in versions.env_json (same on dev and prod).
    # Deployment-specific values (#run_network, #user_data_mount, #env_file_option) are
    # filled at runtime from ENV in build_docker_cmd.
    def canonical_asap_run_docker_call(include_env_file: true)
      env_file_option = include_env_file ? '#env_file_option ' : ''
      "docker run #host_option --name #container_name --network=#run_network " \
        "-e HOST_USER_ID=$(id -u) -e HOST_USER_GID=$(id -g) --entrypoint '/bin/sh' --rm " \
        "#user_data_mount #{env_file_option}#image_name -c"
    end

    # Prefix for ad-hoc `docker run` invocations that execute an R script inside
    # the asap_run container (used by legacy format conversions like
    # MTX->H5 and RDS->Loom). The ENV DOCKER_CALL template is tailored for the
    # Java parsing path (no `-c`, no /srv mount) and cannot be reused here, so
    # we build a dedicated prefix that:
    #   - targets the deployment-specific compose network (ASAP_RUN_DOCKER_NETWORK)
    #   - mounts the user data root so project paths are reachable
    #   - appends `-c` so the caller can pass a single quoted shell command
    def asap_run_docker_cmd_prefix(image_tag)
      run_network = ENV['ASAP_RUN_DOCKER_NETWORK']
      if run_network.blank?
        raise 'ASAP_RUN_DOCKER_NETWORK is missing. Set it in the env file loaded by docker-compose for website/sidekiq (for example: ASAP_RUN_DOCKER_NETWORK=asap2_test_default), then restart those services.'
      end
      "docker run --network=#{run_network} -e HOST_USER_ID=$(id -u) -e HOST_USER_GID=$(id -g) --entrypoint '/bin/sh' --rm #{user_data_docker_volume_mount_arg} #{ENV.fetch('ASAP_DOCKER_NAME', 'fabdavid/asap_run')}:#{image_tag} -c"
    end

    # Yield an IO positioned at the start of the Matrix Market body (plain or gzip-compressed).
    def with_matrix_market_io(path)
      File.open(path, 'rb') do |f|
        magic = f.read(2)
        if magic == "\x1f\x8b"
          Zlib::GzipReader.open(path) { |gz| yield gz }
        else
          f.rewind
          yield f
        end
      end
    end

    # Single-file Matrix Market (coordinate or array) without 10x barcodes/features sidecars.
    def layout_matrix_market_sparse_or_array_file?(path)
      return false unless File.file?(path)

      header = nil
      with_matrix_market_io(path) { |io| header = io.readline }
      s = header.to_s.strip
      return false unless s.start_with?('%%MatrixMarket')

      !!(s =~ /matrix\s+(coordinate|array)\b/i)
    rescue StandardError
      false
    end

    # First non-comment line after the %%MatrixMarket header gives nrow and ncol (coordinate files
    # also list nnz on the same line; array format lists only m and n).
    def matrix_market_row_col_counts(path)
      with_matrix_market_io(path) do |io|
        header = io.readline
        raise ArgumentError, 'Not Matrix Market' unless header.to_s.start_with?('%%MatrixMarket')

        while (line = io.readline)
          t = line.strip
          next if t.empty?
          next if t.start_with?('%')

          parts = t.split
          raise ArgumentError, "Bad Matrix Market dimension line: #{t.inspect}" if parts.size < 2

          return parts[0].to_i, parts[1].to_i
        end
      end
      raise ArgumentError, "No dimension line found in Matrix Market file #{path}"
    end

    # Prefer the path parse.rake passes; also check canonical project root `input_file` when the
    # upload is still named input_file.gz (first bytes are gzip, not %%MatrixMarket) or when the
    # decompressed matrix already lives at input_file.
    def first_matrix_market_source_path_for_conversion(file_path, base_dir)
      candidates = [file_path.to_s, (base_dir + 'input_file').to_s].uniq
      candidates.each do |p|
        next unless File.file?(p)
        return p if layout_matrix_market_sparse_or_array_file?(p)
      end
      nil
    end

    def matrix_market_file_gzip_compressed?(path)
      return false unless File.file?(path)

      File.open(path, 'rb') { |f| f.read(2) } == "\x1f\x8b"
    rescue StandardError
      false
    end

    # HDF5 superblock (Cell Ranger / mtx_to_h5 output, some other matrix containers; not used for .h5ad heuristics here).
    def hdf5_superblock_file?(path)
      return false unless File.file?(path)

      sig = File.binread(path, 8)
      sig == ["894844460d0a1a0a"].pack('H*')
    rescue StandardError
      false
    end

    # Preparsing may already expose 10x or AnnData as HDF5 on disk. The legacy gunzip/tar branch
    # must not run on those streams or the file is corrupted and Java / h5py prep fails.
    def skip_legacy_archive_pipeline_for_v7_h5_matrix?(path)
      return false unless File.file?(path)

      p = path.to_s
      pl = p.downcase
      return true if pl.end_with?('.h5ad')
      return true if pl.end_with?('.h5')
      return true if File.basename(p) == 'input.h5'
      return true if File.basename(p) == 'input_file' && hdf5_superblock_file?(path)

      false
    end

    def legacy_archive_skip_type_for_v7(path)
      pl = path.to_s.downcase
      return 'H5AD' if pl.end_with?('.h5ad')

      'MEX'
    end

    # v7 parsing: write parsing/output.json so the UI can show displayed_error (same shape as HCA errors).
    def write_parsing_output_json_displayed_error(base_dir, logger, messages)
      out = Pathname.new(base_dir.to_s) + 'parsing' + 'output.json'
      FileUtils.mkdir_p(out.parent.to_s)
      lines = Array(messages).flatten.map { |m| m.to_s.strip }.reject(&:blank?)
      lines = ['Parsing failed'] if lines.empty?
      payload = {
        'displayed_error' => lines,
        'status_id' => 4
      }
      File.open(out.to_s, 'w') { |f| f.write(payload.to_json) }
    rescue StandardError => e
      (logger || Rails.logger).error("[Basic] Failed to write parsing output.json: #{e.class} #{e.message}")
    end

    # Preparsing may write file_path under global fus/<id>/ while the Fu now lives under project/fus/<id>/.
    def resolve_preparsed_input_file_path(fu, h_preparsing: nil, project: nil)
      return nil unless fu

      h_prep = h_preparsing
      upload_root = project ? fu.upload_dir_for_project(project) : fu.upload_dir
      if h_prep.nil?
        output_path = upload_root + 'output.json'
        return nil unless output_path.file?

        h_prep = safe_parse_json(output_path.read, {})
      end

      prep_path = h_prep['file_path'].to_s.strip
      return nil if prep_path.blank?

      staging_dir = fu.global_upload_dir.to_s
      if staging_dir.present? && prep_path.start_with?(staging_dir)
        rest = prep_path.delete_prefix(staging_dir).sub(/\A\/+/, '')
        prep_path = File.join(upload_root.to_s, rest)
      end

      File.file?(prep_path) ? prep_path : nil
    end

    # Archive members are often listed with a directory prefix; the UI may submit only the basename.
    def reconcile_archive_sel_name!(parsing_attrs, upload_dir)
      return parsing_attrs unless parsing_attrs.is_a?(Hash)

      sel = parsing_attrs[:sel_name] || parsing_attrs['sel_name']
      return parsing_attrs if sel.blank? || sel.to_s.include?('/')

      output_path = Pathname.new(upload_dir.to_s) + 'output.json'
      return parsing_attrs unless output_path.file?

      h_prep = safe_parse_json(output_path.read, {})
      list_files = Array(h_prep['list_files'])
      return parsing_attrs if list_files.empty?

      sel_s = sel.to_s
      matches = list_files.filter_map do |entry|
        fn = entry.is_a?(Hash) ? entry['filename'] : entry
        fn = fn.to_s.strip
        next if fn.blank?

        fn if fn == sel_s || fn.end_with?("/#{sel_s}")
      end.uniq

      return parsing_attrs unless matches.size == 1

      if parsing_attrs.key?(:sel_name)
        parsing_attrs[:sel_name] = matches.first
      else
        parsing_attrs['sel_name'] = matches.first
      end
      parsing_attrs
    end

    # After archive member selection, detected_format can still be ARCHIVE* while list_groups holds matrix info.
    def effective_preparsing_file_type(h_preparsing)
      fmt = h_preparsing['detected_format'].to_s
      return fmt if fmt.present? && !fmt.match?(/\AARCHIVE/i)

      fp = h_preparsing['file_path'].to_s
      return 'RAW_TEXT' if fp.match?(/\.(txt|tsv|csv)(\.gz)?\z/i)
      return 'MTX' if fp.match?(/\.mtx(\.gz)?\z/i)
      return 'H5AD' if fp.match?(/\.h5ad(\.gz)?\z/i)
      return 'LOOM' if fp.match?(/\.loom\z/i)
      return 'MEX' if fp.match?(/\.h5\z/i)

      if Array(h_preparsing['list_groups']).any? do |g|
           g.is_a?(Hash) && (g['nber_rows'].present? || g['nb_genes'].present?)
         end
        return 'RAW_TEXT'
      end

      fmt
    end

    # 10x / Matrix Market triplet inside a tar.gz (e.g. pbmc3k_filtered_gene_bc_matrices.tar.gz).
    # Returns { matrix:, barcodes:, features: } member paths when the archive has exactly one complete triplet.
    def mtx_triplet_from_archive_list(list_files)
      paths = mtx_archive_list_paths(list_files)
      groups = Hash.new { |h, k| h[k] = {} }

      paths.each do |path|
        role = classify_mtx_archive_member(path)
        next unless role

        dir = File.dirname(path)
        dir = '' if dir == '.'
        groups[dir][role] = path
      end

      complete = groups.select { |_dir, g| g[:matrix] && g[:barcodes] && g[:features] }
      return nil unless complete.size == 1

      complete.values.first
    end

    def mtx_archive_list_paths(list_files)
      Array(list_files).filter_map do |entry|
        path = if entry.is_a?(Hash)
                 entry['filename'] || entry['path']
               else
                 entry
               end
        path = path.to_s.strip
        next if path.blank?
        next if path.end_with?('/')

        path
      end
    end

    def mtx_triplet_base_filename(path)
      name = File.basename(path.to_s)
      loop do
        stripped = name.sub(/\.(gz|bz2|xz)\z/i, '')
        break if stripped == name

        name = stripped
      end
      name
    end

    def classify_mtx_archive_member(path)
      base = mtx_triplet_base_filename(path).downcase
      return :matrix if base.end_with?('.mtx')
      return :barcodes if base.match?(/\Abarcodes?\.(tsv|csv)\z/)
      return :features if base.match?(/\A(genes|features)\.(tsv|csv)\z/)

      nil
    end

    def extract_mtx_triplet_from_archive(archive_path, triplet, dest_dir, logger: Rails.logger)
      raise ArgumentError, 'incomplete MTX triplet' unless triplet.is_a?(Hash) &&
                                                            triplet[:matrix] && triplet[:barcodes] && triplet[:features]

      FileUtils.mkdir_p(dest_dir)
      {
        'matrix.mtx' => triplet[:matrix],
        'barcodes.tsv' => triplet[:barcodes],
        'features.tsv' => triplet[:features]
      }.each do |canonical, member|
        extract_archive_member_to_file(
          archive_path,
          member,
          File.join(dest_dir.to_s, canonical),
          logger: logger
        )
      end
      dest_dir
    end

    def convert_mtx_bundle_dir_to_h5(bundle_dir, h5_path, logger: Rails.logger)
      bundle_dir = Pathname.new(bundle_dir.to_s)
      raise ArgumentError, "missing matrix.mtx in #{bundle_dir}" unless (bundle_dir + 'matrix.mtx').file?

      h5_path = Pathname.new(h5_path.to_s)
      cmd = "#{asap_run_docker_cmd_prefix('v7')} 'Rscript --vanilla /srv/mtx_to_h5.R #{bundle_dir} #{h5_path}'"
      logger.info("[Basic] MTX bundle -> H5: #{cmd}")
      `#{cmd}`
      unless h5_path.file? && h5_path.size.positive?
        raise "mtx_to_h5.R did not produce a non-empty file at #{h5_path}"
      end

      h5_path.to_s
    end

    def mtx_bundle_dimensions(bundle_dir)
      bundle = Pathname.new(bundle_dir.to_s)
      barcodes = bundle + 'barcodes.tsv'
      features = bundle + 'features.tsv'
      raise ArgumentError, "missing barcodes.tsv in #{bundle}" unless barcodes.file?
      raise ArgumentError, "missing features.tsv in #{bundle}" unless features.file?

      n_cells = count_nonempty_lines(barcodes)
      n_genes = count_nonempty_lines(features)
      raise ArgumentError, "empty barcodes or features in #{bundle}" if n_cells <= 0 || n_genes <= 0

      { nber_rows: n_genes, nber_cols: n_cells }
    end

    def build_mtx_archive_preparsing_output(bundle_dir, h5_path: nil)
      dims = mtx_bundle_dimensions(bundle_dir)
      h5 = h5_path.to_s
      use_h5 = h5.present? && File.file?(h5) && File.size(h5).positive?
      {
        'detected_format' => use_h5 ? 'MEX' : 'MTX',
        'file_path' => use_h5 ? h5 : Pathname.new(bundle_dir.to_s).to_s,
        'list_files' => nil,
        'list_groups' => [
          {
            'group' => 'mtx',
            'nber_rows' => dims[:nber_rows],
            'nber_cols' => dims[:nber_cols],
            'nb_genes' => dims[:nber_rows],
            'nb_cells' => dims[:nber_cols],
            'is_count' => 1
          }
        ]
      }
    end

    def count_nonempty_lines(path)
      count = 0
      File.foreach(path.to_s) do |line|
        count += 1 if line.strip.present?
      end
      count
    end

    def raw_text_matrix_file?(path)
      File.file?(path.to_s) && path.to_s.match?(/\.(txt|tsv|csv)\z/i)
    end

    # Scan a tabular matrix the same way Java v7 parseText does (split with limit -1).
    def raw_text_matrix_scan(file_path, gene_name_col: 'first', delimiter: nil, has_header: true)
      raise ArgumentError, "Not a file: #{file_path}" unless File.file?(file_path.to_s)

      delim = raw_text_matrix_delimiter(delimiter)
      header_row = raw_text_matrix_has_header_row?(has_header)
      header_field_count = nil
      expected_data_fields = nil
      n_cells = nil
      n_rows = 0
      bad_rows = []
      line_num = 0

      File.foreach(file_path.to_s, mode: 'r:ASCII-8BIT') do |line|
        line_num += 1
        fields = raw_text_matrix_split_line(line, delim)
        next if fields.size == 1 && fields[0].to_s.empty?

        if header_row && line_num == 1
          header_field_count = fields.size
          next
        end

        if expected_data_fields.nil?
          expected_data_fields = fields.size
          n_cells = raw_text_matrix_java_ncells(
            header_field_count,
            expected_data_fields,
            gene_name_col,
            header_row
          )
        elsif fields.size != expected_data_fields
          bad_rows << [line_num, fields.size]
        end
        n_rows += 1
      end

      {
        consistent: bad_rows.empty?,
        header_field_count: header_field_count,
        expected_data_fields: expected_data_fields,
        n_cells: n_cells,
        n_rows: n_rows,
        bad_rows: bad_rows
      }
    end

    def raw_text_matrix_dimensions(file_path, gene_name_col: 'first', delimiter: nil, has_header: true)
      scan = raw_text_matrix_scan(
        file_path,
        gene_name_col: gene_name_col,
        delimiter: delimiter,
        has_header: has_header
      )
      { nber_rows: scan[:n_rows], nber_cols: scan[:n_cells] }
    end

    def raw_text_matrix_java_ncells(header_field_count, data_field_count, gene_name_col, has_header)
      unless has_header
        return raw_text_matrix_cell_column_count(data_field_count, gene_name_col)
      end
      return nil unless header_field_count.to_i.positive? && data_field_count.to_i.positive?

      if data_field_count == header_field_count + 1
        header_field_count
      elsif data_field_count == header_field_count
        raw_text_matrix_cell_column_count(header_field_count, gene_name_col)
      else
        raw_text_matrix_cell_column_count(data_field_count, gene_name_col)
      end
    end

    def raw_text_matrix_expected_data_fields(n_cells, gene_name_col)
      n = n_cells.to_i
      return nil unless n.positive?

      case gene_name_col.to_s.downcase
      when 'first', 'last'
        n + 1
      else
        n
      end
    end

    # Use a clean matrix file for Java parsing. Re-extract from the upload archive when the
    # on-disk copy has inconsistent row widths (common after legacy tar conversion).
    def materialize_raw_text_matrix_for_parse!(filepath:, fu:, parsing_attrs:, tmp_dir:, logger: Rails.logger)
      fp = filepath.to_s
      gene_name_col = parsing_attrs['gene_name_col'] || parsing_attrs[:gene_name_col] || 'first'
      delimiter = parsing_attrs.key?('delimiter') ? parsing_attrs['delimiter'] : parsing_attrs[:delimiter]
      has_header = parsing_attrs.key?('has_header') ? parsing_attrs['has_header'] : parsing_attrs[:has_header]
      has_header = '1' if has_header.nil? || has_header == ''

      if raw_text_matrix_file?(fp)
        scan = raw_text_matrix_scan(
          fp,
          gene_name_col: gene_name_col,
          delimiter: delimiter,
          has_header: has_header
        )
        if scan[:consistent] && scan[:n_cells].to_i.positive?
          return Pathname.new(fp)
        end

        logger.warn(
          "[Basic] RAW_TEXT matrix at #{fp} is inconsistent for Java " \
          "(expected #{scan[:expected_data_fields]} fields/row, #{scan[:bad_rows].size} bad rows)"
        )
      end

      archive_path, member_path = resolve_raw_text_archive_member(fu, parsing_attrs, fp)
      unless archive_path.present? && member_path.present?
        validate_raw_text_matrix_for_java!(
          fp,
          gene_name_col: gene_name_col,
          delimiter: delimiter,
          has_header: has_header
        ) if raw_text_matrix_file?(fp)
        return Pathname.new(fp)
      end

      dest = Pathname.new(tmp_dir) + 'raw_text_matrix.tsv'
      extract_archive_member_to_file(archive_path, member_path, dest, logger: logger)
      scan = raw_text_matrix_scan(
        dest.to_s,
        gene_name_col: gene_name_col,
        delimiter: delimiter,
        has_header: has_header
      )
      unless scan[:consistent] && scan[:n_cells].to_i.positive?
        examples = scan[:bad_rows].first(5).map { |ln, nf| "line #{ln}=#{nf}" }.join(', ')
        raise "Matrix #{member_path} in #{archive_path} has inconsistent row widths " \
              "(expected #{scan[:expected_data_fields]} tab fields per row). #{examples}"
      end

      logger.info(
        "[Basic] Materialized RAW_TEXT matrix from #{archive_path}:#{member_path} -> #{dest} " \
        "(#{scan[:n_rows]} genes x #{scan[:n_cells]} cells)"
      )
      dest
    end

    def validate_raw_text_matrix_for_java!(file_path, gene_name_col: 'first', delimiter: nil, has_header: true)
      scan = raw_text_matrix_scan(
        file_path,
        gene_name_col: gene_name_col,
        delimiter: delimiter,
        has_header: has_header
      )
      return scan if scan[:consistent]

      examples = scan[:bad_rows].first(5).map { |ln, nf| "line #{ln} has #{nf} fields" }.join('; ')
      raise "Tabular matrix #{file_path} has #{scan[:bad_rows].size} row(s) with the wrong number of " \
            "tab-separated fields (expected #{scan[:expected_data_fields]} per data row). #{examples}"
    end

    def resolve_raw_text_archive_member(fu, parsing_attrs, current_filepath)
      sel = parsing_attrs['sel_name'] || parsing_attrs[:sel_name]
      if sel.blank? && fu
        output_path = fu.upload_dir + 'output.json'
        if output_path.file?
          h_prep = safe_parse_json(output_path.read, {})
          prep_path = h_prep['file_path'].to_s
          if prep_path.present?
            basename = File.basename(prep_path)
            list_files = Array(h_prep['list_files'])
            matches = list_files.filter_map do |entry|
              fn = entry.is_a?(Hash) ? entry['filename'] : entry
              fn = fn.to_s.strip
              next if fn.blank?

              fn if fn == basename || fn.end_with?("/#{basename}")
            end.uniq
            sel = matches.first if matches.size == 1
          end
        end
      end
      return [nil, nil] if sel.blank?

      attrs = { 'sel_name' => sel.to_s }
      attrs = reconcile_archive_sel_name!(attrs, fu.upload_dir) if fu
      member_path = attrs['sel_name'] || attrs[:sel_name]

      archive_candidates = []
      archive_candidates << fu.file_path if fu
      archive_candidates << current_filepath.to_s
      if fu
        upload_dir = fu.upload_dir.to_s
        Dir.glob(File.join(upload_dir, 'input_file.tar*')).each { |p| archive_candidates << p }
        Dir.glob(File.join(upload_dir, 'input_file.tgz')).each { |p| archive_candidates << p }
      end

      archive_path = archive_candidates.find do |c|
        c.present? && File.file?(c.to_s) && c.to_s.match?(/\.(tar\.gz|tgz|tbz2|txz|tar)(\..*)?\z/i)
      end
      [archive_path, member_path]
    end

    def extract_archive_member_to_file(archive_path, member_path, dest_path, logger: Rails.logger)
      archive_path = File.expand_path(archive_path.to_s)
      dest_path = File.expand_path(dest_path.to_s)
      member_path = member_path.to_s
      FileUtils.mkdir_p(File.dirname(dest_path))

      cmd = if archive_path.match?(/\.(tar\.gz|tgz)(\..*)?\z/i)
              ['tar', '-xOzf', archive_path, member_path]
            elsif archive_path.match?(/\.tar(\..*)?\z/i)
              ['tar', '-xOf', archive_path, member_path]
            else
              raise "Unsupported archive format for RAW_TEXT extraction: #{archive_path}"
            end

      logger.info("[Basic] Extracting #{member_path} from #{archive_path} to #{dest_path}")
      File.open(dest_path, 'wb') do |out|
        IO.popen(cmd, 'rb', err: [:child, :out]) do |io|
          IO.copy_stream(io, out)
        end
      end
      unless $?.success?
        raise "Failed to extract #{member_path} from #{archive_path} (exit #{$?.exitstatus})"
      end
      dest_path
    end

    def raw_text_matrix_delimiter(delimiter)
      delim = delimiter.nil? ? "\t" : delimiter.to_s
      delim.empty? ? "\t" : delim
    end

    def raw_text_matrix_has_header_row?(has_header)
      has_header != false && has_header != '0' && has_header.to_s.downcase != 'false'
    end

    def raw_text_matrix_split_line(line, delim)
      line.b.delete_suffix("\n").delete_suffix("\r").split(delim.b, -1)
    end

    def raw_text_matrix_cell_column_count(field_count, gene_name_col)
      count = field_count.to_i
      return count if count <= 0

      case gene_name_col.to_s.downcase
      when 'first', 'last'
        count - 1
      else
        count
      end
    end

    def sync_raw_text_dimensions_from_file!(output, gene_name_col: 'first', delimiter: nil, has_header: true)
      return output unless output.is_a?(Hash)

      fp = output['file_path'].to_s
      return output unless raw_text_matrix_file?(fp)

      dims = raw_text_matrix_dimensions(
        fp,
        gene_name_col: gene_name_col,
        delimiter: delimiter,
        has_header: has_header
      )
      return output if dims[:nber_rows].to_i <= 0 || dims[:nber_cols].to_i <= 0

      groups = Array(output['list_groups'])
      if groups.any?
        groups.each do |g|
          next unless g.is_a?(Hash)

          g['nber_rows'] = dims[:nber_rows]
          g['nber_cols'] = dims[:nber_cols]
          g['nb_genes'] = dims[:nber_rows] if g.key?('nb_genes')
          g['nb_cells'] = dims[:nber_cols] if g.key?('nb_cells')
        end
      else
        output['nber_rows'] = dims[:nber_rows]
        output['nber_cols'] = dims[:nber_cols]
      end
      output
    end

    def get_asap_docker_for_markers project
      version = project.version
      asap_docker_image = get_asap_docker(version)
      return asap_docker_image if !asap_docker_image

      # FindMarkers is not available in ASAP v4; pin only this step to v5.
      # v8+ uses de.v8.py FindAllMarkers on the project's own asap_run image.
      if asap_docker_major_version(asap_docker_image) < 8 && asap_docker_image.tag == 'v4'
        return DockerImage.find_by!(name: asap_docker_image.name, tag: 'v5')
      end

      asap_docker_image
    end

    def asap_docker_major_version(docker_image)
      tag = docker_image&.tag.to_s
      m = tag.match(/\Av?(\d+)/i)
      m ? m[1].to_i : 0
    end

    def markers_use_python_de?(docker_image)
      asap_docker_major_version(docker_image) >= 8
    end

    def marker_groups_annot_id project, meta
      cloned_project_id = project.respond_to?(:cloned_project_id) ? project.cloned_project_id : nil
      return meta.id if cloned_project_id.blank?

      source_meta = Annot.where(
        project_id: cloned_project_id,
        name: meta.name,
        latest_version: true
      ).order(version_nber: :desc, id: :desc).first

      if source_meta.nil?
        source_key = Project.find_by(id: cloned_project_id)&.key || "id #{cloned_project_id}"
        column = meta.name.to_s.presence || "this metadata column"
        raise SourceAnnotResolutionError, "FindMarkers needs the same metadata column on the project this copy was cloned from (#{source_key}). " \
                                            "There is no current latest-version column matching #{column.inspect} there anymore " \
                                            "(it may have been removed, renamed, or version-replaced). " \
                                            "Open the clone source project or use a metadata column that still exists on both projects."
      end

      source_meta.id
    end

    def command_json_boolean_truthy?(val)
      val == true || val == 1 || val.to_s.strip.casecmp('true').zero?
    end

    # Bulk pipeline: gene filtering is single-run per loom; resolve its row filter flag path from
    # the selected input_matrix run lineage (same loom filepath). Used by clustering.bulk.v8.R --filter_meta.
    def filter_mdata_from_lineage(project_id, lineage_run_ids, loom_filepath)
      loom_filepath = loom_filepath.to_s.strip
      return nil if loom_filepath.blank?

      ids = Array(lineage_run_ids).map(&:to_i).reject { |id| id <= 0 }.uniq
      return nil if ids.empty?

      Annot.joins(:step).where(
        project_id: project_id,
        run_id: ids,
        steps: { name: 'gene_filtering' },
        filepath: loom_filepath,
        dim: 2
      ).where("annots.name LIKE ?", "/row_attrs/_gene_filter_%")
       .order(id: :desc)
       .pick(:name)
    end

    # std_method attrs_json (per attr): optional "dropdown_placeholder" (or "placeholder") on
    # input_data widgets sets the closed dropdown label instead of "-- Select <label> --".
    #
    # std_method attrs_json (per attr): for input_data attrs whose valid_types include "dataset",
    # set_run sets h_var[attr_name] to the dataset field string (e.g. output_attr_name). For attrs
    # named "groups" / "groups2", set_run also sets h_var["groups_annot_id"] and h_var["groups2_annot_id"]
    # from the selection's annot_id (comma-separated if multiple) so command_json can reference
    # those param_keys without use_annot_id.
    # Optional: "set_h_var_to_annot_id": true stores the id in h_var[attr_name] itself instead of the
    # dataset field string; do not combine that with use_annot_id on the same param_key.
    #
    # command_json may request 0-based category indices for the CLI instead of labels,
    # or numeric annot ids instead of loom metadata names (e.g. Wilcoxon -meta).
    #
    # Optional on any args[] or opts[] entry (any step): after resolving #{...} placeholders,
    # omit_when_null skips the entry if the value is blank (nothing added). You do not need
    # null_value on that entry; it is only for entries that stay on the command with a literal
    # when the resolved value is blank.
    # valueless_flag: for argparse-style boolean flags (store_true). When the resolved value is
    # truthy, emit only the flag name (e.g. --chunked) with no following argument; when falsy,
    # skip the entry entirely. Do not combine with a truthy checkbox value on the command line.
    # omit_when_all_against_compl skips when attrs["all_against_compl"] is true (same mechanism,
    # useful when the value can be non-empty but the flag must still drop the cli flag).
    #
    # Example (differential expression / de.v8.py style opts):
    #   { "opt": "--group1", "param_key": "group_ref", "use_group_category_index": true,
    #     "omit_when_null": true }
    #   { "opt": "--group2", "param_key": "group_comp", "use_group_category_index": true,
    #     "category_annot_param_key": "groups2", "omit_when_null": true }
    # When category_annot_param_key is set but that attr is empty, the default attrs["groups"] annot is used.
    #   { "opt": "-meta", "param_key": "metadata", "use_annot_id": true }
    #
    # de.v8.py db file (written in the run output_dir before the container starts). In merged command_json:
    #   "db_json": { "filename": "db.json", "annots": ["metadata", "groups_annot_id", "groups2_annot_id"] }
    # "annots" lists h_var param keys whose values are annot id(s) (comma-separated allowed). Optional "filename"
    # defaults to db.json. set_run writes JSON {"annots":[{<Annot as_json>}, ...]} to that file and persists on
    # the saved command_json, e.g. "db_json": { "filename", "annots", "annot_ids" } for get_commands.
    #
    # Legacy top-level:
    #   "group1_use_category_index": true, "group2_use_category_index": true
    #   "group1": { "use_category_index": true }, "group2": { "use_category_index": true }
    def command_json_use_category_index_for_de_group?(h_cmd, group_key)
      return false unless h_cmd.is_a?(Hash)

      top = h_cmd["#{group_key}_use_category_index"]
      return true if command_json_boolean_truthy?(top)

      nested = h_cmd[group_key.to_s]
      return false unless nested.is_a?(Hash)

      command_json_boolean_truthy?(nested['use_category_index'])
    end

    def command_json_group_category_mode_for_entry(entry)
      return nil unless entry.is_a?(Hash)
      return :pos if command_json_boolean_truthy?(entry['use_group_category_pos'])
      return :index if command_json_boolean_truthy?(entry['use_group_category_index'])

      nil
    end

    def de_group_category_mode_by_param_key(h_cmd)
      return {} unless h_cmd.is_a?(Hash)

      modes = {}
      %w[args opts].each do |list_key|
        (h_cmd[list_key] || []).each do |entry|
          mode = command_json_group_category_mode_for_entry(entry)
          next if mode.nil?

          pk = entry['param_key'].to_s
          next if pk.blank?

          # If both are present on duplicate entries for the same param_key, keep one-based mode.
          modes[pk] = mode if modes[pk] != :pos
        end
      end

      modes['group_ref'] ||= :index if command_json_use_category_index_for_de_group?(h_cmd, 'group1')
      modes['group_comp'] ||= :index if command_json_use_category_index_for_de_group?(h_cmd, 'group2')
      modes
    end

    def skip_command_json_arg_or_opt_entry?(entry, h_var, p, value_after_template_expand)
      return false unless entry.is_a?(Hash)

      if command_json_boolean_truthy?(entry['omit_when_all_against_compl'])
        if command_json_boolean_truthy?(h_var['all_against_compl']) || command_json_boolean_truthy?(p['all_against_compl'])
          return true
        end
      end

      if command_json_boolean_truthy?(entry['omit_when_null'])
        v = value_after_template_expand
        return true if v.nil? || v.to_s.strip == ''
      end

      if command_json_boolean_truthy?(entry['valueless_flag'])
        return true unless command_json_boolean_truthy?(value_after_template_expand)
      end

      false
    end

    def de_param_keys_requiring_annot_id(h_cmd)
      return [] unless h_cmd.is_a?(Hash)

      keys = []
      %w[args opts].each do |list_key|
        (h_cmd[list_key] || []).each do |entry|
          next unless entry.is_a?(Hash)
          next unless command_json_boolean_truthy?(entry['use_annot_id'])

          pk = entry['param_key']
          keys << pk.to_s if pk.present?
        end
      end
      keys.uniq
    end

    # ExtractMetadata JSON for 2D gene metadata may list values as either:
    # - column-major: values[col][gene_idx] (outer size = nber_cols), or
    # - row-major: values[gene_idx][col] (outer size = nber_rows).
    # run_de_filter and downstream filter_de assume column-major. This normalizes to column-major arrays.
    def de_attrs_values_to_column_major(vals, json_nber_rows, json_nber_cols, annot)
      return [vals, 'skip:not_nested_array'] unless vals.is_a?(Array) && vals[0].is_a?(Array)

      outer = vals.size
      inner = vals.map { |r| r.is_a?(Array) ? r.size : 0 }.max
      nr = annot.nber_rows.to_i
      nc = annot.nber_cols.to_i
      jr = json_nber_rows.to_i
      jc = json_nber_cols.to_i
      nr = jr if nr <= 0 && jr.positive?
      nc = jc if nc <= 0 && jc.positive?

      if nr.positive? && nc.positive? && outer == nc && inner >= nr
        return [vals, "column_major json_nr=#{jr} json_nc=#{jc} annot_nr=#{annot.nber_rows} annot_nc=#{annot.nber_cols} outer=#{outer} inner=#{inner}"]
      end

      if nr.positive? && nc.positive? && outer == nr && inner >= nc
        transposed = (0...nc).map do |ci|
          (0...outer).map do |ri|
            row = vals[ri]
            row.is_a?(Array) && ci < row.size ? row[ci] : nil
          end
        end
        return [transposed, "transposed_row_major json_nr=#{jr} json_nc=#{jc} annot_nr=#{annot.nber_rows} annot_nc=#{annot.nber_cols} outer=#{outer} inner=#{inner}"]
      end

      headers = safe_parse_json(annot.headers_json_value, [])
      hlen = headers.is_a?(Array) ? headers.size : 0
      if hlen >= 5 && (outer == hlen || outer == hlen + 1) && inner > outer * 5
        return [vals, "column_major_via_headers hlen=#{hlen} outer=#{outer} inner=#{inner}"]
      end
      if hlen >= 5 && (inner == hlen || inner == hlen + 1) && outer > inner * 5
        transposed = (0...inner).map do |ci|
          (0...outer).map do |ri|
            row = vals[ri]
            row.is_a?(Array) && ci < row.size ? row[ci] : nil
          end
        end
        return [transposed, "transposed_via_headers hlen=#{hlen} outer=#{outer} inner=#{inner}"]
      end

      if inner.positive? && inner < 256 && outer > inner * 50
        transposed = (0...inner).map do |ci|
          (0...outer).map do |ri|
            row = vals[ri]
            row.is_a?(Array) && ci < row.size ? row[ci] : nil
          end
        end
        return [transposed, "transposed_heuristic outer=#{outer} inner=#{inner}"]
      end

      [vals, "unknown_assume_column_major outer=#{outer} inner=#{inner} nr=#{nr} nc=#{nc} jr=#{jr} jc=#{jc}"]
    end

    # DE /attrs matrices: legacy runs expose five numeric columns (logFC, P-value, FDR, Avg group1, Avg group2)
    # as the first columns in ExtractMetadata JSON "values". v8+ may prepend string columns; column titles
    # are stored on Annot#headers_json (same order as output.json "headers", before optional leading HDF5-only
    # fields such as Gene). Returns 0-based indices into values[col][gene_idx] for those five metrics in order,
    # plus sort_idx (logFC source column) for ranking rows. Falls back to [0,1,2,3,4] when headers are absent
    # or ambiguous.
    def de_normalize_de_header_label(s)
      s.to_s.strip.downcase.gsub(/\s+/, ' ')
    end

    def de_metric_indices_from_header_names(headers)
      return nil unless headers.is_a?(Array) && headers.any?

      nh = headers.map { |h| de_normalize_de_header_label(h) }
      logfc = nh.index { |x| %w[logfc log2fc].include?(x) || x.match?(/\Alog2?fc\z/) || (x.include?('fold') && x.include?('change')) }
      pval = nh.index { |x| %w[p-value p value pvalue p_val p.val].include?(x) || x.match?(/\Ap[\._]?value\z/) }
      fdr = nh.index { |x| x == 'fdr' || x.match?(/\Aadj\.?\s*p/) || x.start_with?('padj') }
      avg1 = nh.index { |x| x == 'avg group1' || x == 'avg_group1' || (x.include?('avg') && x.include?('group') && x.match?(/1/)) }
      avg2 = nh.index { |x| x == 'avg group2' || x == 'avg_group2' || (x.include?('avg') && x.include?('group') && x.match?(/2/)) }
      return nil if logfc.nil? || pval.nil? || fdr.nil? || avg1.nil? || avg2.nil?

      { logfc: logfc, p_value: pval, fdr: fdr, avg1: avg1, avg2: avg2 }
    end

    def de_tail_headers_are_legacy_metric_pack?(five_headers)
      m = de_metric_indices_from_header_names(five_headers)
      m && m[:logfc].zero? && m[:p_value] == 1 && m[:fdr] == 2 && m[:avg1] == 3 && m[:avg2] == 4
    end

    def de_metric_source_indices_for_extract_metadata(annot, n_value_cols)
      n = n_value_cols.to_i
      return { indices: [0, 1, 2, 3, 4], sort_idx: 0 } if n < 5

      headers = safe_parse_json(annot.headers_json_value, [])
      headers = [] unless headers.is_a?(Array)

      offset = 0
      if headers.any? && n == headers.size + 1
        offset = 1
      end

      if headers.size >= 5
        tail = headers.last(5)
        if de_tail_headers_are_legacy_metric_pack?(tail)
          start_h = headers.size - 5
          idxs = (0...5).map { |k| start_h + k + offset }
          return { indices: idxs, sort_idx: idxs[0] } if idxs.max < n
        end
      end

      by_name = de_metric_indices_from_header_names(headers)
      if by_name
        idxs = %i[logfc p_value fdr avg1 avg2].map { |k| by_name[k] + offset }
        return { indices: idxs, sort_idx: idxs[0] } if idxs.max < n
      end

      { indices: [0, 1, 2, 3, 4], sort_idx: 0 }
    end

    def de_format_output_txt_metric_value(val, metric_slot)
      if val.nil? || val.to_s.strip.empty? || val.to_s.strip.casecmp('na').zero?
        return 'NA'
      end

      if [1, 2].include?(metric_slot) || !val.is_a?(Float)
        val
      elsif val.abs > 0.001
        format('%.3f', val)
      else
        format('%.e', val)
      end
    end

    def de_output_txt_first_line_is_column_header?(line)
      t = line.to_s.strip.split("\t")
      return false if t.empty?

      return false if Integer(t[0], exception: false)

      t[0].strip.casecmp('gene index').zero?
    end

    # v8 all-against-complementary DE: HDF paths like /attrs/de_<run_id>_<k> (k = contrast index).
    # Returns [run_id_from_name, contrast_index] so paths work even when Annot.run_id points at another pipeline row.
    def de_attrs_de_output_matrix_match(name)
      s = name.to_s.strip
      return nil if s.blank?

      s = s.sub(/\Aattrs\//, '/attrs/')
      m = s.match(%r{\A/attrs/de_(\d+)_(\d+)\z}i)
      return nil unless m

      [m[1].to_i, m[2].to_i]
    end

    def de_attrs_de_output_annot?(annot)
      annot && de_attrs_de_output_matrix_match(annot.name)
    end

    # Loom filepath (relative to project dir) for this run, from attrs input_matrix when present.
    def de_run_loom_relative_filepath(run)
      return nil unless run

      h = safe_parse_json(run.attrs_json, {})
      im = h['input_matrix'] || h[:input_matrix]
      if im.is_a?(Hash)
        aid = (im['annot_id'] || im[:annot_id]).to_i
        if aid.positive?
          a = Annot.find_by(id: aid)
          return a.filepath if a&.filepath.present?
        end
      end
      nil
    end

    # All DE contrast matrix annots for this run: prefer Annot.run_id match, then name /attrs/de_<run.id>_k on same loom.
    def de_attrs_de_output_annots_for_run(run, by_run)
      rid = run.id
      from_run = Array(by_run[rid])
      matched = from_run.select do |a|
        m = de_attrs_de_output_matrix_match(a.name)
        m && m[0] == rid
      end

      if matched.size <= 1
        fp = de_run_loom_relative_filepath(run)
        rel_scope = Annot.where(project_id: run.project_id)
        extra = if fp.present?
                  rel_scope.where(filepath: fp).to_a.select do |a|
                    m = de_attrs_de_output_matrix_match(a.name)
                    m && m[0] == rid
                  end
                elsif ApplicationRecord.connection.adapter_name.match?(/postgresql/i)
                  pat = "^(/attrs/|attrs/)de_#{rid.to_i}_[0-9]+$"
                  rel_scope.where('name ~* ?', pat).to_a.select do |a|
                    m = de_attrs_de_output_matrix_match(a.name)
                    m && m[0] == rid
                  end
                else
                  rel_scope.to_a.select do |a|
                    m = de_attrs_de_output_matrix_match(a.name)
                    m && m[0] == rid
                  end
                end
        matched = (matched + extra).uniq(&:id)
      end

      matched.sort_by do |a|
        m = de_attrs_de_output_matrix_match(a.name)
        m ? m[1] : 0
      end
    end

    # One TSV per v8 contrast: de/<run_id>/annot_<annot_id>/output.txt (tab-separated; separate file per contrast).
    # Legacy single-file DE: de/<run_id>/output.txt
    def de_annot_output_txt_path(project_dir, annot, run_id: nil)
      base = project_dir.is_a?(Pathname) ? project_dir : Pathname.new(project_dir.to_s)
      m_attrs = annot && de_attrs_de_output_matrix_match(annot.name)
      rid = m_attrs ? m_attrs[0] : (annot&.run_id || run_id)
      raise ArgumentError, 'de_annot_output_txt_path needs annot or run_id' if rid.blank?

      rid = rid.to_i
      if m_attrs
        ((base + 'de') + rid.to_s) + "annot_#{annot.id}" + 'output.txt'
      else
        ((base + 'de') + rid.to_s) + 'output.txt'
      end
    end

    # Directory containing output.txt and filtered.{up,down}.json for DE gene lists.
    def de_filter_gene_list_dir(project_dir, run_id, de_annot_id)
      base = project_dir.is_a?(Pathname) ? project_dir : Pathname.new(project_dir.to_s)
      rid = run_id.to_i
      annot = nil
      if de_annot_id.to_i.positive?
        cand = Annot.find_by(id: de_annot_id.to_i)
        if cand && de_attrs_de_output_matrix_match(cand.name)
          m = de_attrs_de_output_matrix_match(cand.name)
          annot = cand if m && m[0] == rid
        elsif cand && cand.run_id.to_i == rid
          annot = cand
        end
      end
      if annot && de_attrs_de_output_matrix_match(annot.name)
        Pathname(de_annot_output_txt_path(base, annot)).dirname
      else
        (base + 'de') + rid.to_s
      end
    end

    # Slug used inside h_stats / JSON keys (run_id + contrast index + category label).
    def de_stats_key_category_slug(reference_group, contrast_index)
      k = contrast_index.to_i
      raw = reference_group.to_s.strip
      label = raw.downcase.gsub(/[^a-z0-9]+/, '_').squeeze('_').gsub(/\A_+|_+\z/, '')[0, 56]
      label = 'group' if label.blank?

      "#{k}_#{label}"
    end

    # Key for filtered DE stats (must stay stable for a given contrast). Legacy: run id only.
    def de_de_filter_stats_key(run, annot:, reference_group:, contrast_index:)
      return run.id.to_s if annot.nil?

      rid = (de_attrs_de_output_matrix_match(annot.name)&.first || run.id).to_i
      k = contrast_index.nil? ? (de_attrs_de_output_matrix_match(annot.name)&.last || 0) : contrast_index.to_i
      slug = de_stats_key_category_slug(reference_group, k)

      "#{rid}__#{slug}"
    end

    # Same rules as lib/filter_de.cpp: tab TSV columns 5 = logFC, 7 = FDR; writes filtered.{up,down}.json beside output.txt.
    # Prefer the compiled filter_de binary (single-threaded, streaming, low memory).
    def de_filter_write_filtered_json!(output_txt_path, fdr_cutoff, fc_cutoff)
      path = output_txt_path.to_s
      return { 'up' => 0, 'down' => 0 } unless File.exist?(path) && File.size(path).positive?

      fdr_c = fdr_cutoff.to_f
      fc_val = fc_cutoff.to_f
      fc_val = 1.0 if fc_val <= 0

      native = de_filter_via_native_binary(path, fdr_c, fc_val)
      return native if native

      de_filter_write_filtered_json_ruby!(path, fdr_c, fc_val)
    end

    # Filter many output.txt files in one native process (avoids per-file spawn cost).
    # jobs: [{ key:, path: }, ...]  => { key => { 'up' => N, 'down' => M } }
    def de_filter_write_filtered_json_batch!(jobs, fdr_cutoff, fc_cutoff)
      fdr_c = fdr_cutoff.to_f
      fc_val = fc_cutoff.to_f
      fc_val = 1.0 if fc_val <= 0

      valid = Array(jobs).map do |job|
        key = job[:key].to_s
        path = job[:path].to_s
        next if key.blank? || path.blank?
        next unless File.exist?(path) && File.size(path).positive?

        { key: key, path: path }
      end.compact
      return {} if valid.empty?

      native = de_filter_via_native_batch(valid, fdr_c, fc_val)
      return native if native

      valid.each_with_object({}) do |job, acc|
        acc[job[:key]] = de_filter_write_filtered_json_ruby!(job[:path], fdr_c, fc_val)
      end
    end

    def de_filter_binary_path
      candidates = [
        Rails.root.join('lib', 'filter_de').to_s,
        File.expand_path('filter_de', __dir__)
      ]
      candidates.find { |p| File.file?(p) && File.executable?(p) }
    end

    # filter_de --file OUTPUT_TXT FDR FC  -> writes filtered.{up,down}.json; prints "UP DOWN"
    def de_filter_via_native_binary(path, fdr_c, fc_val)
      bin = de_filter_binary_path
      return nil unless bin

      require 'open3'
      out, err, status = Open3.capture3(bin, '--file', path, fdr_c.to_s, fc_val.to_s)
      unless status.success?
        Rails.logger.warn(
          "[de_filter] native filter_de failed path=#{path} status=#{status.exitstatus} stderr=#{err.to_s.strip.truncate(300)}"
        )
        return nil
      end

      parts = out.to_s.strip.split(/\s+/)
      if parts.size < 2
        Rails.logger.warn("[de_filter] native filter_de bad stdout path=#{path} stdout=#{out.to_s.strip.truncate(200)}")
        return nil
      end

      up = Integer(parts[0], exception: false)
      down = Integer(parts[1], exception: false)
      if up.nil? || down.nil?
        Rails.logger.warn("[de_filter] native filter_de non-integer counts path=#{path} stdout=#{out.to_s.strip.truncate(200)}")
        return nil
      end

      { 'up' => up, 'down' => down }
    end

    # filter_de --batch FDR FC < paths  -> lines "PATH\tUP\tDOWN"
    def de_filter_via_native_batch(jobs, fdr_c, fc_val)
      bin = de_filter_binary_path
      return nil unless bin

      require 'open3'
      stdin_data = jobs.map { |j| j[:path] }.join("\n") + "\n"
      out, err, status = Open3.capture3(bin, '--batch', fdr_c.to_s, fc_val.to_s, stdin_data: stdin_data)
      unless status.success?
        Rails.logger.warn(
          "[de_filter] native filter_de --batch failed status=#{status.exitstatus} stderr=#{err.to_s.strip.truncate(300)}"
        )
        return nil
      end

      by_path = jobs.each_with_object({}) { |j, acc| acc[j[:path]] = j[:key] }
      result = {}
      out.to_s.each_line do |line|
        path, up_s, down_s = line.strip.split("\t")
        key = by_path[path]
        next unless key

        up = Integer(up_s, exception: false)
        down = Integer(down_s, exception: false)
        next if up.nil? || down.nil?

        result[key] = { 'up' => up, 'down' => down }
      end

      if result.size != jobs.size
        Rails.logger.warn(
          "[de_filter] native filter_de --batch incomplete expected=#{jobs.size} got=#{result.size}"
        )
        return nil
      end

      result
    end

    def de_filter_write_filtered_json_ruby!(path, fdr_c, fc_val)
      log_fc_c = Math.log2(fc_val)
      vec_up = []
      vec_down = []
      i = 0

      File.open(path, 'rb') do |io|
        io.each_line do |line|
          col5, col7 = de_filter_tsv_cols_5_and_7(line)
          if col5 && col7 && col5 != 'NA' && col7 != 'NA'
            fdr = Float(col7, exception: false)
            logfc = Float(col5, exception: false)
            if fdr && logfc && fdr <= fdr_c
              if logfc >= log_fc_c
                vec_up << i
              elsif logfc <= -log_fc_c
                vec_down << i
              end
            end
          end
          i += 1
        end
      end

      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      File.binwrite(File.join(dir, 'filtered.up.json'), "[#{vec_up.join(',')}]")
      File.binwrite(File.join(dir, 'filtered.down.json'), "[#{vec_down.join(',')}]")
      { 'up' => vec_up.size, 'down' => vec_down.size }
    end

    # Extract 0-based TSV columns 5 (logFC) and 7 (FDR) without allocating a full split array.
    def de_filter_tsv_cols_5_and_7(line)
      len = line.bytesize
      len -= 1 while len.positive? && (line.getbyte(len - 1) == 10 || line.getbyte(len - 1) == 13)
      return [nil, nil] if len <= 0

      col = 0
      start = 0
      col5 = nil
      col7 = nil
      pos = 0
      while pos < len
        if line.getbyte(pos) == 9
          if col == 5
            col5 = line.byteslice(start, pos - start)
          elsif col == 7
            col7 = line.byteslice(start, pos - start)
            return [col5, col7]
          end
          col += 1
          start = pos + 1
        end
        pos += 1
      end
      if col == 7
        col7 = line.byteslice(start, len - start)
      elsif col == 5
        col5 = line.byteslice(start, len - start)
      end
      [col5, col7]
    end

    # GE enrichment reads gene row ids from tmp/<user_id>_<de_run_id>_<fc>_<fdr>_filtered_ids.json
    # (same rules as lib/filter_de.cpp ge_form mode).
    # Heatmap step: resolve the selected gene set into gene identifiers and write a
    # single self-contained heatmap_config.json into the run output_dir before the
    # container starts. heatmap.v8.py reads it via --config. This makes the run fully
    # specified and reproducible (genes, category selection, transform, clustering opts).
    def write_heatmap_config!(project:, output_dir:, h_var:, p:)
      out = output_dir.is_a?(Pathname) ? output_dir : Pathname.new(output_dir.to_s)
      FileUtils.mkdir_p(out.to_s) unless File.exist?(out.to_s)

      resolved = HeatmapGeneResolver.resolve(
        project: project,
        item_id: p['global_gene_set_item_id'],
        collection_id: p['global_gene_set_collection_id']
      )

      config = {
        'gene_identifiers' => resolved.genes,
        'cells_metadata' => h_var['cells_metadata'].presence,
        'cells_categories' => heatmap_normalize_list(p['cells_metadata_sel']),
        'column_mode' => p['column_mode'].presence || 'cells',
        'group_metadata' => h_var['group_metadata'].presence,
        'value_transform' => p['value_transform'].presence || 'zscore',
        'max_cells' => (p['max_cells'].presence || 5000).to_i,
        'seed' => (p['seed'].presence || 42).to_i,
        'cluster_rows' => command_json_boolean_truthy?(p.fetch('cluster_rows', true)),
        'cluster_cols' => command_json_boolean_truthy?(p.fetch('cluster_cols', true)),
        'linkage_method' => p['linkage_method'].presence || 'ward',
        'distance_metric' => p['distance_metric'].presence || 'euclidean',
        'warnings' => resolved.warnings
      }

      File.write((out + 'heatmap_config.json').to_s, JSON.pretty_generate(config))
      config
    end

    def heatmap_normalize_list(val)
      case val
      when Array then val.map(&:to_s).reject(&:empty?)
      when nil then []
      else val.to_s.split(',').map(&:strip).reject(&:empty?)
      end
    end

    def heatmap_split_paths(val)
      return [] if val.nil?
      val.to_s.split(',').map(&:strip).reject(&:empty?)
    end

    def write_ge_filtered_ids_json!(project_dir:, user_id:, input_de_run_id:, fdr_cutoff:, fc_cutoff:, input_de:, h_annots: {})
      run_id = input_de_run_id.to_i
      raise ArgumentError, 'Missing DE run for gene enrichment' unless run_id.positive?

      base = project_dir.is_a?(Pathname) ? project_dir : Pathname.new(project_dir.to_s)
      input_de_item = input_de.is_a?(Array) ? input_de.first : input_de
      output_txt = nil
      if input_de_item.is_a?(Hash)
        annot_id = (input_de_item['annot_id'] || input_de_item[:annot_id]).to_i
        annot = h_annots[annot_id] if annot_id.positive?
        annot ||= Annot.find_by(id: annot_id) if annot_id.positive?
        output_txt = de_annot_output_txt_path(base, annot) if annot
      end
      output_txt ||= ((base + 'de') + run_id.to_s) + 'output.txt'
      unless File.exist?(output_txt.to_s) && File.size(output_txt.to_s).positive?
        raise StandardError, "DE output file not found for gene enrichment (#{output_txt})"
      end

      fdr_c = fdr_cutoff.to_f
      fc_val = fc_cutoff.to_f
      fc_val = 1.0 if fc_val <= 0
      log_fc_c = Math.log2(fc_val)
      vec_up_ids = []
      vec_down_ids = []
      File.foreach(output_txt.to_s, mode: 'rt', encoding: 'UTF-8') do |line|
        cols = line.chomp.split("\t")
        next if cols.size <= 7 || cols[7] == 'NA' || cols[5] == 'NA'

        fdr = Float(cols[7]) rescue nil
        logfc = Float(cols[5]) rescue nil
        gene_id = Float(cols[0]) rescue nil
        next unless fdr && logfc && gene_id && fdr <= fdr_c

        if logfc >= 0 && logfc >= log_fc_c
          vec_up_ids << gene_id.to_i
        elsif logfc <= 0 && logfc <= -log_fc_c
          vec_down_ids << gene_id.to_i
        end
      end

      tmp_dir = base + 'tmp'
      FileUtils.mkdir_p(tmp_dir.to_s)
      dest = tmp_dir + "#{user_id}_#{run_id}_#{fc_cutoff}_#{fdr_cutoff}_filtered_ids.json"
      File.write(dest.to_s, JSON.generate({ 'down' => vec_down_ids, 'up' => vec_up_ids }))
      dest.to_s
    end

    # First discrete groups annot id from run attrs (v8 DE: list_cat_json order matches /attrs/de_<run>_k).
    def de_groups_discrete_annot_id_for_de_table(run)
      return nil unless run

      h = safe_parse_json(run.attrs_json, {})
      g = h['groups'] || h[:groups]
      if g.is_a?(Array) && g[0].is_a?(Hash)
        aid = (g[0]['annot_id'] || g[0][:annot_id]).to_i
        return aid if aid.positive?
      end
      if h['groups_annot_id'].present?
        found = h['groups_annot_id'].to_s.split(',').map(&:strip).reject(&:blank?).map(&:to_i).find { |id| id.positive? }
        return found if found
      end
      gid = (h['groups_id'] || h[:groups_id]).to_i
      return gid if gid.positive?

      g2 = h['groups2'] || h[:groups2]
      if g2.is_a?(Array) && g2[0].is_a?(Hash)
        aid2 = (g2[0]['annot_id'] || g2[0][:annot_id]).to_i
        return aid2 if aid2.positive?
      end

      nil
    end

    def de_reference_group_label_for_contrast_index(groups_annot, contrast_index)
      return nil unless groups_annot

      list_cats = de_group_category_labels_from_list_cat_json(safe_parse_json(groups_annot.list_cat_json, []))
      return nil if list_cats.blank?

      idx = contrast_index.to_i
      return nil if idx.negative? || idx >= list_cats.size

      list_cats[idx].nil? ? nil : list_cats[idx].to_s.strip.presence
    end

    def de_table_rows_for_runs(completed_runs)
      return [] if completed_runs.blank?

      run_ids = completed_runs.map(&:id)
      project_id = completed_runs.first.project_id
      by_run = Annot.where(run_id: run_ids).group_by(&:run_id)

      # One batched lookup for v8 /attrs/de_<run_id>_<k> annots. Avoids the old
      # per-run fallback that could scan all project annots on every filter refresh.
      by_de_run_from_name = de_attrs_de_output_annots_by_run_id(project_id, run_ids)

      group_annot_ids = completed_runs.map { |r| de_groups_discrete_annot_id_for_de_table(r) }.compact.uniq
      groups_annots_by_id = group_annot_ids.any? ? Annot.where(id: group_annot_ids).index_by(&:id) : {}

      rows = []
      completed_runs.each do |run|
        gid = de_groups_discrete_annot_id_for_de_table(run)
        groups_annot = gid ? groups_annots_by_id[gid] : nil

        from_run = Array(by_run[run.id]).select do |a|
          m = de_attrs_de_output_matrix_match(a.name)
          m && m[0] == run.id
        end
        attrs_des = (from_run + Array(by_de_run_from_name[run.id])).uniq(&:id).sort_by do |a|
          m = de_attrs_de_output_matrix_match(a.name)
          m ? m[1] : 0
        end

        if attrs_des.any?
          attrs_des.each do |a|
            m = de_attrs_de_output_matrix_match(a.name)
            k = m ? m[1] : 0
            ref_label = de_reference_group_label_for_contrast_index(groups_annot, k)
            rows << {
              run: run,
              annot: a,
              contrast_index: k,
              reference_group: ref_label,
              stats_key: de_de_filter_stats_key(run, annot: a, reference_group: ref_label, contrast_index: k)
            }
          end
        else
          rows << { run: run, annot: nil, contrast_index: nil, reference_group: nil, stats_key: run.id.to_s }
        end
      end
      rows
    end

    # Batch-load v8 DE contrast matrix annots keyed by run id from the name.
    def de_attrs_de_output_annots_by_run_id(project_id, run_ids)
      rid_list = Array(run_ids).map(&:to_i).uniq
      return {} if project_id.blank? || rid_list.empty?

      scope = Annot.where(project_id: project_id)
      candidates =
        if ApplicationRecord.connection.adapter_name.match?(/postgresql/i)
          scope.where('name ~* ?', "^(/attrs/|attrs/)de_(#{rid_list.join('|')})_[0-9]+$").to_a
        else
          scope.where('name LIKE ? OR name LIKE ?', '%/de_%', 'attrs/de_%').to_a.select do |a|
            m = de_attrs_de_output_matrix_match(a.name)
            m && rid_list.include?(m[0])
          end
        end

      candidates.group_by { |a| de_attrs_de_output_matrix_match(a.name)&.first }.tap { |h| h.delete(nil) }
    end

    # list_cat_json is normally a JSON array of category labels (metadata import / add_cell_sets).
    # A JSON object of categories is ordered like Basic metadata key ordering.
    def de_group_category_labels_from_list_cat_json(parsed)
      case parsed
      when Array
        parsed
      when Hash
        keys = parsed.keys
        ordered_keys = if keys.all? { |k| k.to_s.match?(/\A-?\d+\z/) }
                         keys.sort_by { |k| k.to_i }
                       elsif keys.all? { |k| k.to_s.match?(/\A-?\d*\.?\d+\z/) }
                         keys.sort_by { |k| k.to_f }
                       else
                         keys.sort { |a, b| a.to_s <=> b.to_s }
                       end
        ordered_keys.map { |k| parsed[k] }
      else
        []
      end
    end

    def de_group_category_label_index(list_cats, raw)
      target = raw.to_s.strip
      list_cats.each_index.find do |i|
        list_cats[i].nil? ? false : list_cats[i].to_s.strip == target
      end
    end

    # Resolves one list_cat_json entry, or several CXG-style labels joined with " || " when
    # list_cat_json stores each term separately (e.g. ontology term ids per cell vs. compound values).
    # Returns a string for h_var: one index, or comma-separated indices for the CLI.
    def de_group_category_index_string_from_label_value(list_cats, raw, one_based: false)
      raw_s = raw.to_s.strip
      return nil if raw_s.empty?

      idx = de_group_category_label_index(list_cats, raw_s)
      return (one_based ? idx + 1 : idx).to_s unless idx.nil?

      return nil unless raw_s.include?(' || ')

      parts = raw_s.split(' || ').map(&:strip).reject(&:empty?)
      return nil if parts.length < 2

      indices = parts.map { |part| de_group_category_label_index(list_cats, part) }
      return nil if indices.any?(&:nil?)

      indices = indices.map { |i| one_based ? i + 1 : i }
      indices.uniq.join(',')
    end

    # Same distinct labels and sort order as AnnotationsController#categories (live loom).
    # list_cat_json can lag edits or differ from what the visualization DE dropdown shows.
    def de_discrete_category_labels_from_loom_for_de_indexing(annot, project, logger)
      user_data_dir = ENV['USER_DATA_DIR'].presence || Rails.root.join('storage', 'user_data').to_s
      project_dir = Pathname.new(user_data_dir) + project.user_id.to_s + project.key
      loom_path = project_dir + annot.filepath.to_s
      return nil unless File.exist?(loom_path.to_s)

      values = H5DataService.get_metadata_vector(loom_path.to_s, annot.name)
      return nil unless values.is_a?(Array)

      seen = {}
      values.each do |value|
        cat = (value.nil? || value.to_s.empty?) ? 'NA' : value.to_s
        seen[cat] = true
      end
      seen.keys.sort
    rescue StandardError => e
      logger&.warn("[set_run] discrete category list from loom skipped annot=#{annot.id}: #{e.class} #{e.message}")
      nil
    end

    # When attrs["groups2"] was never persisted (restart / old runs) but group_comp labels clearly
    # belong to another discrete column on the same loom (e.g. FBdv stages vs FBbt cell types).
    # Returns { annot:, list_cats:, label_source:, idx_str: } or nil. Tie-break: lowest annot id.
    def de_infer_discrete_annot_for_unmatched_group_comp(project, h_annots, primary_annot, raw, logger, one_based: false)
      return nil if primary_annot.blank? || raw.blank?

      fp = primary_annot.filepath.to_s
      return nil if fp.empty?

      candidates = h_annots.values.compact.select do |a|
        a.id != primary_annot.id &&
          a.project_id == project.id &&
          a.filepath.to_s == fp &&
          a.dim.to_i == 1 &&
          a.data_type_id.to_i == 3 &&
          a.name.to_s.start_with?('/col_attrs/') &&
          a.latest_version != false
      end

      best = nil
      candidates.each do |cand|
        list_c = de_discrete_category_labels_from_loom_for_de_indexing(cand, project, logger)
        src = 'loom'
        if list_c.nil? || list_c.empty?
          list_c = de_group_category_labels_from_list_cat_json(Basic.safe_parse_json(cand.list_cat_json, []))
          src = 'list_cat_json'
        end
        next if list_c.blank?

        idx = de_group_category_index_string_from_label_value(list_c, raw, one_based: one_based)
        next unless idx

        if best.nil? || cand.id < best[:annot].id
          best = {
            annot: cand,
            list_cats: list_c,
            label_source: "#{src} (inferred same-loom column)",
            idx_str: idx
          }
        end
      end
      if best && logger
        logger.info("[set_run] group_comp inferred metadata column annot=#{best[:annot].id} (#{best[:annot].name.inspect}); primary was #{primary_annot.id}")
      end
      best
    end

    def annot_for_de_group_category_mapping(p, h_annots, project)
      groups = p['groups']
      if groups.is_a?(Array) && groups[0].is_a?(Hash) && groups[0]['annot_id'].present?
        aid = groups[0]['annot_id'].to_i
        annot = h_annots[aid] if h_annots.is_a?(Hash)
        return annot if annot

        return Annot.find_by(id: aid, project_id: project.id)
      end

      if p['groups_id'].present?
        gid = p['groups_id'].to_i
        annot = h_annots[gid] if h_annots.is_a?(Hash)
        return annot if annot

        return Annot.find_by(id: gid, project_id: project.id)
      end

      nil
    end

    def annot_from_de_input_data_selection(raw, h_annots, project)
      parsed = raw.is_a?(String) ? Basic.safe_parse_json(raw, {}) : raw
      parsed = parsed[0] if parsed.is_a?(Array) && parsed[0].is_a?(Hash)
      return nil unless parsed.is_a?(Hash)

      aid = (parsed['annot_id'] || parsed[:annot_id]).to_i
      return nil if aid <= 0

      annot = h_annots[aid] if h_annots.is_a?(Hash)
      return annot if annot

      Annot.find_by(id: aid, project_id: project.id)
    end

    # DE form toggles (see de_second_metadata_attrs.js): compared categories come from attrs["groups2"].
    def de_second_metadata_column_enabled_for_de?(h_var, p)
      %w[second_group_from_other_metadata group_comp_from_other_metadata].any? do |k|
        command_json_boolean_truthy?(h_var[k] || p[k])
      end
    end

    # Optional on opts/args next to use_group_category_index/use_group_category_pos:
    # "category_annot_param_key": "groups2"
    # so group_comp maps against list_cat_json of attrs["groups2"] instead of attrs["groups"].
    def category_annot_param_key_for_group_index(h_cmd, param_key)
      return nil unless h_cmd.is_a?(Hash)

      pk = param_key.to_s
      %w[args opts].each do |list_key|
        (h_cmd[list_key] || []).each do |entry|
          next unless entry.is_a?(Hash)
          next if command_json_group_category_mode_for_entry(entry).nil?
          next unless entry['param_key'].to_s == pk

          cap = entry['category_annot_param_key'].to_s.strip
          return cap if cap.present?
        end
      end
      nil
    end

    def annot_for_de_group_category_index_param(h_cmd_params, param_key, p, h_var, h_annots, project)
      capk = category_annot_param_key_for_group_index(h_cmd_params, param_key)
      if capk.present?
        raw = h_var[capk] || p[capk]
        if raw.present? && raw.to_s.strip != ''
          annot = annot_from_de_input_data_selection(raw, h_annots, project)
          unless annot
            raise StandardError, "use_group_category_index for #{param_key.inspect} uses category_annot_param_key #{capk.inspect} but attrs did not resolve to an annot (invalid JSON selection)"
          end
          return annot
        end
        # Second metadata column not used (empty attr): use the same default annot as group_ref.
      end

      # Compared group labels come from attrs["groups2"] when second-metadata mode is on, but
      # step command_json often omits category_annot_param_key: "groups2". Map group_comp against
      # groups2's annot in that case (e.g. FBdv stages vs FBbt cell types on primary groups).
      if param_key.to_s == 'group_comp' && de_second_metadata_column_enabled_for_de?(h_var, p)
        g2_raw = h_var['groups2'] || p['groups2']
        if g2_raw.present? && g2_raw.to_s.strip != ''
          annot = annot_from_de_input_data_selection(g2_raw, h_annots, project)
          return annot if annot
        end
      end

      annot = annot_for_de_group_category_mapping(p, h_annots, project)
      return annot if annot

      raise StandardError, 'use_group_category_index requires attrs["groups"] with annot_id, or attrs["groups_id"], pointing to the grouping metadata annot (unless category_annot_param_key is set on the command opt)'
    end

    def apply_de_group_category_indices_from_command_json!(logger, h_cmd_params, h_var, p, h_annots, project)
      param_modes = de_group_category_mode_by_param_key(h_cmd_params)
      return if param_modes.empty?

      all_against_compl = command_json_boolean_truthy?(p['all_against_compl'])

      param_modes.each do |pk, mode|
        one_based = mode == :pos
        mode_name = one_based ? 'use_group_category_pos' : 'use_group_category_index'
        raw_preflight = h_var[pk] || p[pk]
        if all_against_compl && %w[group_ref group_comp].include?(pk.to_s) && (raw_preflight.nil? || raw_preflight.to_s.strip.empty?)
          logger.debug("[set_run] skipping #{mode_name} for #{pk} (all_against_complementary)")
          next
        end

        annot = annot_for_de_group_category_index_param(h_cmd_params, pk, p, h_var, h_annots, project)

        list_cats = de_discrete_category_labels_from_loom_for_de_indexing(annot, project, logger)
        label_source = 'loom'
        if list_cats.nil? || list_cats.empty?
          parsed = Basic.safe_parse_json(annot.list_cat_json, [])
          list_cats = de_group_category_labels_from_list_cat_json(parsed)
          label_source = 'list_cat_json'
        end
        if list_cats.empty?
          logger.warn("[set_run] #{mode_name} set but annot #{annot.id} has no usable categories (loom empty/unreadable and list_cat_json empty); skipping #{pk} (e.g. binary 0/1 selections)")
          next
        end

        raw = h_var[pk]
        raise StandardError, "#{mode_name} is set for param_key #{pk.inspect} but that value is missing in attrs" if raw.nil? || raw.to_s.strip.empty?

        idx_str = de_group_category_index_string_from_label_value(list_cats, raw, one_based: one_based)
        # Restart uses persisted attrs_json; second-metadata toggles are often absent even when
        # group_comp was chosen from attrs["groups2"]. If labels fit the second column, use it.
        if idx_str.nil? && pk.to_s == 'group_comp'
          g2_raw = h_var['groups2'] || p['groups2']
          if g2_raw.present? && g2_raw.to_s.strip != ''
            g2_annot = annot_from_de_input_data_selection(g2_raw, h_annots, project)
            primary_annot_id = annot.id
            if g2_annot && g2_annot.id != primary_annot_id
              list_g2 = de_discrete_category_labels_from_loom_for_de_indexing(g2_annot, project, logger)
              src_g2 = 'loom'
              if list_g2.nil? || list_g2.empty?
                list_g2 = de_group_category_labels_from_list_cat_json(Basic.safe_parse_json(g2_annot.list_cat_json, []))
                src_g2 = 'list_cat_json'
              end
              if list_g2.present?
                idx_g2 = de_group_category_index_string_from_label_value(list_g2, raw, one_based: one_based)
                if idx_g2
                  annot = g2_annot
                  list_cats = list_g2
                  label_source = "#{src_g2} (groups2 annot #{g2_annot.id})"
                  idx_str = idx_g2
                  logger.info("[set_run] group_comp matched groups2 column annot=#{g2_annot.id} (#{g2_annot.name.inspect}); primary groups annot was #{primary_annot_id}")
                end
              end
            end
          end
        end
        if idx_str.nil? && pk.to_s == 'group_comp'
          inferred = de_infer_discrete_annot_for_unmatched_group_comp(project, h_annots, annot, raw, logger, one_based: one_based)
          if inferred
            annot = inferred[:annot]
            list_cats = inferred[:list_cats]
            label_source = inferred[:label_source]
            idx_str = inferred[:idx_str]
          end
        end
        if idx_str.nil?
          preview = list_cats.first(15).map(&:inspect).join(', ')
          more = list_cats.size > 15 ? " (+#{list_cats.size - 15} more)" : ''
          raise StandardError, "#{pk} value #{raw.inspect} is not a category label for annot #{annot.id} (name #{annot.name.inspect}; labels from #{label_source}). Examples: #{preview}#{more}"
        end
        h_var[pk] = idx_str
        logger.debug("[set_run] DE group label mapped to index string: #{pk}=#{h_var[pk]} annot_id=#{annot.id}")
      end
    end

    # command_json: per opt/arg, "use_annot_id": true replaces the attr value (metadata column
    # name, e.g. /col_attrs/Cluster) with this project's latest-version Annot id for the CLI.
    # For grouping columns, prefer h_var["groups_annot_id"] / h_var["groups2_annot_id"] (set by set_run)
    # with param_key groups_annot_id / groups2_annot_id instead of use_annot_id on "groups".
    def apply_de_annot_ids_from_command_json!(logger, h_cmd_params, h_var, project)
      param_keys = de_param_keys_requiring_annot_id(h_cmd_params)
      return if param_keys.empty?

      param_keys.each do |pk|
        raw = h_var[pk]
        raise StandardError, "use_annot_id is set for param_key #{pk.inspect} but that value is missing in attrs" if raw.nil? || raw.to_s.strip.empty?

        name = raw.to_s.strip
        annot = Annot.where(project_id: project.id, name: name, latest_version: true)
                       .order(version_nber: :desc, id: :desc)
                       .first
        unless annot
          raise StandardError, "#{pk} value #{name.inspect} is not a latest-version metadata name for this project (no matching annot)"
        end

        h_var[pk] = annot.id.to_s
      end

      logger.debug("[set_run] metadata names mapped to annot ids: #{param_keys.map { |k| "#{k}=#{h_var[k]}" }.join(' ')}")
    end

    def de_db_json_spec(h_cmd_params)
      return nil unless h_cmd_params.is_a?(Hash)

      spec = h_cmd_params['db_json']
      return nil unless spec.is_a?(Hash)

      keys = spec['annots']
      return nil unless keys.is_a?(Array) && keys.any?

      fn = File.basename(spec['filename'].to_s.presence || 'db.json')
      fn = 'db.json' if fn.blank? || fn == '.'

      { filename: fn, param_keys: keys.map(&:to_s).reject(&:blank?) }
    end

    def de_annot_ids_from_db_json_param_keys(h_var, p, param_keys)
      ids = []
      param_keys.each do |pk|
        raw = nil
        raw = h_var[pk] if h_var.is_a?(Hash)
        raw = p[pk] if raw.nil? && p.is_a?(Hash)
        raw = p[pk.to_sym] if raw.nil? && p.is_a?(Hash)
        next if raw.nil? || raw.to_s.strip.empty?

        raw.to_s.split(',').each do |part|
          n = part.to_i
          ids << n if n.positive?
        end
      end
      ids.uniq
    end

    def de_db_json_payload_from_annot_ids(annot_ids, project_id)
      clean_ids = Array(annot_ids).map(&:to_i).select(&:positive?).uniq
      return nil if clean_ids.empty?

      rows = Annot.where(id: clean_ids, project_id: project_id).order(:id).map(&:as_json)
      { 'annots' => rows }
    end

    def write_de_db_json!(logger, h_cmd_params, h_var, p, project, output_dir)
      spec = de_db_json_spec(h_cmd_params)
      return nil unless spec

      annot_ids = de_annot_ids_from_db_json_param_keys(h_var, p, spec[:param_keys])
      if annot_ids.empty?
        raise StandardError,
              "db_json is configured but no positive annot ids were resolved from db_json.annots #{spec[:param_keys].inspect}"
      end

      payload = de_db_json_payload_from_annot_ids(annot_ids, project.id)
      if !payload || payload['annots'].empty?
        raise StandardError,
              "db_json: no Annot rows for project_id=#{project.id} with ids #{annot_ids.inspect}"
      end

      target = output_dir + spec[:filename]
      File.open(target.to_s, 'w') { |f| f.write(JSON.generate(payload)) }
      logger&.debug("[set_run] wrote #{spec[:filename]} (#{payload['annots'].size} annot row(s), ids #{annot_ids.join(',')})")

      {
        'filename' => spec[:filename],
        'annots' => spec[:param_keys],
        'annot_ids' => annot_ids
      }
    end

    def ensure_markers_original_gene_attr logger, loom_filename
      return if loom_filename.blank? || !File.exist?(loom_filename)

      # Many FindMarkers runs share the same loom; h5py "r+" takes an exclusive HDF5 lock and
      # concurrent opens raise BlockingIOError. Serialize per loom path with flock.
      lock_path = "#{loom_filename}.markers_loom_lock"
      File.open(lock_path, File::CREAT | File::RDWR) do |lockf|
        lockf.flock(File::LOCK_EX)

        py_script = <<~PY
          import h5py
          import sys
          p = #{loom_filename.to_s.inspect}
          with h5py.File(p, "r") as f:
              if "row_attrs" not in f:
                  raise RuntimeError("Loom row_attrs group is missing")
              row = f["row_attrs"]
              if "Original_Gene" in row:
                  print("original_gene_exists")
                  sys.exit(0)
              if "Gene" not in row:
                  raise RuntimeError("Loom row_attrs/Gene dataset is missing")
          with h5py.File(p, "r+") as f:
              row = f["row_attrs"]
              if "Original_Gene" in row:
                  print("original_gene_exists")
              elif "Gene" in row:
                  data = row["Gene"][...]
                  row.create_dataset("Original_Gene", data=data)
                  print("original_gene_created")
              else:
                  raise RuntimeError("Loom row_attrs/Gene dataset is missing")
        PY

        require 'open3'
        out, err, status = Open3.capture3('docker', 'exec', '-i', ENV.fetch('ASAP_RUN_CONTAINER'), 'python', '-', stdin_data: py_script)
        if !status.success?
          raise "Failed to ensure /row_attrs/Original_Gene in loom file #{loom_filename}: #{out} #{err}"
        end
        logger.debug("[FindMarkers] #{out.strip}") unless out.to_s.strip.empty?
      end
    end
    
    def find_marker_enrichment logger, project, meta, find_marker_run, user_id
      t = Time.now
      project_dir =  Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
      version = project.version
      h_env = JSON.parse(version.env_json)
      
      #   list_docker_image_names = h_env['docker_images'].keys.map{|k| h_env['docker_images'][k]["name"] + ":" + h_env['docker_images'][k]["tag"]}
      #   docker_images = DockerImage.where("full_name in (#{list_docker_image_names.map{|e| "'#{e}'"}.join(",")})").all
      #   asap_docker_image = docker_images.select{|e| e.name == ENV.fetch('ASAP_DOCKER_NAME')}.first
      asap_docker_image = get_asap_docker(version)
      runtime_marker_docker_image = get_asap_docker_for_markers(project)
      marker_docker_entry = h_env['docker_images'] && h_env['docker_images']['asap_run']
      if marker_docker_entry && runtime_marker_docker_image
        marker_docker_entry['name'] = runtime_marker_docker_image.name
        marker_docker_entry['tag'] = runtime_marker_docker_image.tag
      end
      
#      find_marker_step = Step.where(:version_id => project.version_id, :name => 'markers').first
      find_marker_step = Step.where(:docker_image_id => asap_docker_image.id, :name => 'markers').first 
#      find_marker_enrichment_step = Step.where(:version_id => project.version_id, :name => 'marker_enrich').first
      find_marker_enrichment_step = Step.where(:docker_image_id => asap_docker_image.id, :name => 'marker_enrich').first
      #      std_method = StdMethod.where(:version_id => project.version_id, :name => 'asap_marker_enrichment').first
      std_method = StdMethod.where(:docker_image_id => asap_docker_image.id, :name => 'asap_marker_enrichment').first
      
      h_cmd_params = JSON.parse(find_marker_step.command_json)
      tmp_h = JSON.parse(std_method.command_json)
      tmp_h.each_key do |k|
        h_cmd_params[k] = tmp_h[k]
      end
      
      docker_image = h_cmd_params['docker_image']
      
      matrix = Annot.where(:project_id => project.id, :dim => 3, :name => "/matrix", :filepath => meta.filepath).first
      
      last_run = Run.where(:project_id => project.id, :step_id => find_marker_step.id).order("id desc").first
      if find_marker_run
        input_dir = project_dir + find_marker_step.name + find_marker_run.id.to_s
        puts "MARKER_ENRICH_STEP: " + find_marker_enrichment_step.to_json
        puts "MARKER_ENRICH_METHOD: " + std_method.to_json
        
        h_data_classes = {}
        DataClass.all.map{|dc| h_data_classes[dc.id] = dc}
        
        puts "TEST_ENRICH: " + meta.to_json
        
        if matrix and meta #and last_run                                                                                         
          puts "TEST_ENRICH2: " + meta.to_json
          genesets = Basic.sql_query2(:asap_data, h_env['asap_data_db_version'], 'gene_sets', '', 'id', "organism_id = #{project.organism_id}")
          
          h_attrs = {
            :input_dir => input_dir,
            :nber_files => Dir.new(input_dir).entries.select{|e| !e.match(/^\./) and e.match(/cat_\d+.tsv/)}.size,
            :geneset_ids => genesets.map{|gs| gs.id}.join(",")          
          }
          
          h_run = {
            :project_id => project.id,
            :step_id => find_marker_enrichment_step.id,
            :std_method_id => std_method.id,
            :status_id => 6, #status_id, # set as running                                                                                 
            :num => (last_run) ? last_run.num + 1 : 1,
            :user_id => user_id,
            :command_json => "{}", #h_cmd.to_json,                          
            :attrs_json => h_attrs.to_json, #self.parsing_attrs_json,
            :output_json => "{}", #h_outputs.to_json,
            :lineage_run_ids => '{}', #lineage_run_ids.join(","),
            :submitted_at => Time.now,
            :pipeline_parent_run_ids => find_marker_run.id
          }
          
          
          if find_marker_enrichment_step and std_method
            
            puts "h_run: " + h_run.to_json 
            run = Run.where({:project_id => project.id,
                              :step_id => find_marker_enrichment_step.id,
                              :std_method_id => std_method.id,
                              :attrs_json => h_attrs.to_json
                            }).first
            if run
              run.update(h_run)
            else
              run = Run.new(h_run)
              run.save
            end
            
            output_dir =  project_dir + find_marker_enrichment_step.name
            Dir.mkdir output_dir if !File.exist? output_dir
            output_dir += run.id.to_s
            if File.exist? output_dir
              FileUtils.rm_r output_dir
            end
            Dir.mkdir output_dir
            
            # set run                                                                                                   
            h_run_attrs = JSON.parse(run.attrs_json)
            h_res = Basic.get_std_method_attrs(std_method, find_marker_step)
            h_attrs = h_res[:h_attrs]
            #    @h_global_params = h_res[:h_global_params]                                                                                                                                            
            h_p = {
              :project => project,
              :h_cmd_params => h_cmd_params,
              :run => run,
              :p => h_run_attrs, #list_of_runs2[run_i][1],                                                                                                                                   
              :h_attrs => h_attrs,
              :step => find_marker_step,
              :h_data_classes => h_data_classes,
              :std_method => std_method,
              :h_env => h_env,
              :el_time => t,
              :user_id => user_id #(current_user) ? current_user.id : 1                                                                                                                      
            }
            h_res = Basic.set_run(logger, h_p)
      
            children_runs = JSON.parse(find_marker_run.children_run_ids)
            children_runs.push run.id if !children_runs.include? run.id
            find_marker_run.update_attribute(:children_run_ids, children_runs.to_json)

          end          
          
        end
        
      end
    end

    def find_markers logger, project, meta, user_id

      run = nil
      t = Time.now
      project_dir =  Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
      version = project.version
      h_env = JSON.parse(version.env_json)
      #      list_docker_image_names = h_env['docker_images'].keys.map{|k| h_env['docker_images'][k]["name"] + ":" + h_env['docker_images'][k]["tag"]}
      #      docker_images = DockerImage.where("full_name in (#{list_docker_image_names.map{|e| "'#{e}'"}.join(",")})").all
      #      asap_docker_image = docker_images.select{|e| e.name == ENV.fetch('ASAP_DOCKER_NAME')}.first
      asap_docker_image = get_asap_docker(version)
      runtime_marker_docker_image = get_asap_docker_for_markers(project)
      marker_docker_entry = h_env['docker_images'] && h_env['docker_images']['asap_run']
      if marker_docker_entry && runtime_marker_docker_image
        marker_docker_entry['name'] = runtime_marker_docker_image.name
        marker_docker_entry['tag'] = runtime_marker_docker_image.tag
      end
      #find_marker_step = Step.where(:version_id => project.version_id, :name => 'markers').first
      find_marker_step = Step.where(:docker_image_id => asap_docker_image.id, :name => 'markers').first 

      # std_method = StdMethod.where(:version_id => project.version_id, :name => 'asap_markers').first
      std_method = StdMethod.where(:docker_image_id => asap_docker_image.id, :name => 'asap_markers').first 
      
      h_cmd_params = JSON.parse(find_marker_step.command_json)
      tmp_h = JSON.parse(std_method.command_json)
      tmp_h.each_key do |k|
        h_cmd_params[k] = tmp_h[k]
      end

      docker_image = h_cmd_params['docker_image']
      
      #   parsing_matrix = Annot.where(:project_id => project.id, :dim => 3, :name => "/matrix", :filepath => "parsing/output.loom").first
      matrix = Annot.where(:project_id => project.id, :dim => 3, :name => "/matrix", :filepath => meta.filepath).first
      # puts parsing_matrix

      matrix_run = Run.where(:project_id => project.id, :id => matrix.run_id).first      

      last_run = Run.where(:project_id => project.id, :step_id => find_marker_step.id).order("id desc").first

      h_data_classes = {}
      DataClass.all.map{|dc| h_data_classes[dc.id] = dc}
      
      if matrix and meta #and last_run
        begin
          marker_groups_id = marker_groups_annot_id(project, meta)
        rescue SourceAnnotResolutionError => e
          logger.error("[find_markers] #{e.class}: #{e.message}")
          return { run: nil, error: e.message }
        end

        ensure_markers_original_gene_attr(logger, project_dir + meta.filepath) unless markers_use_python_de?(runtime_marker_docker_image)
        h_attrs = {
  #        #        {"input_de":{"annot_id":168794,"run_id":32390},"fdr_cutoff":"0.05","fc_cutoff":"2","gene_set_id":"672","adj_method":"fdr","min":"15","max":"500"}
#          :input_matrix_filename => project_dir + meta.filepath,
#          :input_matrix_dataset => '/matrix',
          :input_matrix => {"annot_id" => matrix.id,"run_id" => matrix.run_id},
          :groups_filename => project_dir + meta.filepath, #[{:annot_id => matrix.id, :run_id => matrix.run_id, :output_filename => matrix.filepath}],
          :groups_dataset => meta.name,
          :groups_id => marker_groups_id
        }

        h_run = {
          :project_id => project.id,
          :step_id => find_marker_step.id,
          :std_method_id => std_method.id,
          :status_id => 6, #status_id, # set as running      
          :num => (last_run) ? last_run.num + 1 : 1,
          :user_id => user_id,
          # :command_json => "{}", #h_cmd.to_json,        
          :command_json => "{}", #h_cmd.to_json,
          :attrs_json => h_attrs.to_json, #self.parsing_attrs_json,
          :run_parents_json => "[]", #{"run_id" => matrix.run_id,"type" => "dataset","output_attr_name" => "output_matrix","input_attr_name" => "input_matrix"}].to_json,
#          :h_annots => {meta.id => meta, matrix.id => matrix},
          :output_json => "{}", #h_outputs.to_json,
          :lineage_run_ids => '{}', #lineage_run_ids.join(","),
          :submitted_at => Time.now
        }
        logger.debug("H_RUN => #{h_run.to_json}")
        #        h_cmd = {
        #          :program => "java -jar lib/ASAP.jar", # "rails parse[#{self.key}]",  #(mem > 10) ? "java -Xms#{mem}g -Xmx#{mem}g -jar /srv/ASAP.jar#" : 'java -jar /srv/ASAP.jar',        
        #          :opts => [
        #                    {"opt" => "-T", "value" => "CreateCellSelection"},
        #                    {"opt" => "-loom", "param_key" => "loom_filename", "value" => project_dir + loom_file},
        #                    #                  {"opt" => "-o", "value" => run_dir},                 
        #                    {"opt" => "-meta", "param_key" => 'annot_name', "value" => annot_name},
        #                    {"opt" => '-f', "value" => cell_indexes_filename}
        #                  ],
        #        :args => []
        #     }
        
        if find_marker_step and std_method

          # Reuse only non-failed runs for identical marker requests.
          # Failed runs must stay immutable so polling does not flip them back to queued.
          run = Run.where({:project_id => project.id,
                            :step_id => find_marker_step.id,
                            :std_method_id => std_method.id,
                            :attrs_json => h_attrs.to_json
                          }).where.not(status_id: 4).order(id: :desc).first
          if run
            # Do not overwrite command_json when reusing; set_run will build it.
            run.update(h_run.except(:command_json))
          else
            run = Run.new(h_run)
            logger.debug("H_RUN2 => #{h_run.to_json}")
            run.save
            logger.debug("created RUN:" + run.to_json)
          end
          output_dir = project_dir + find_marker_step.name 
          Dir.mkdir output_dir if !File.exist? output_dir
          output_dir = project_dir + find_marker_step.name + run.id.to_s
          if File.exist? output_dir
            FileUtils.rm_r output_dir
          end
          Dir.mkdir output_dir

#          
#          # set command
#
#          host_name =  h_cmd_params['host_name'] || 'localhost'
#          container_name = ENV.fetch('ASAP_INSTANCE_NAME') + "_" + run.id.to_s
#          
#          h_env_docker_image =h_env['docker_images'][docker_image]
#          image_name = h_env_docker_image['name'] + ":" + h_env_docker_image['tag']
#
#          h_cmd = {
#            :host_name => host_name,
#            :container_name => container_name,
#            :docker_call => (docker_image) ? h_env_docker_image['call'].gsub(/\#image_name/, image_name) : nil,
#            :time_call => h_env['time_call'].gsub(/(\#[\w_]+)/) { |var| h_var[var[1..-1]] },
#            :exec_stdout => h_env['exec_stdout'].gsub(/(\#[\w_]+)/) { |var| h_var[var[1..-1]] },
#            :exec_stderr => h_env['exec_stderr'].gsub(/(\#[\w_]+)/) { |var| h_var[var[1..-1]] },            
#            :program => h_cmd_params[:program],
#            :opts => [
#                      {"opt" => "--loom", "param_key" => "loom_filename", "value" => matrix.filepath},
#                      {"opt" => "--iAnnot", "param_key" => 'annot_name', "value" => meta.name},
#                      {"opt" => '-o', "value" => output_dir + 'output.json'},
#                      {"opt" => '--id', "value" => meta.id }
#                     ]
#            #          :input_matrix => {:annot_id => parsing_matrix.id, :run_id => parsing_matrix.run_id, :output_filename => parsing_matrix.filepath},                                                                                                                                   #    
#            #          :annot_id => meta.id                                                                                                  #    
#          }
#          
#          h_upd = {
#            :command_json => h_cmd.to_json,    
#            :status_id => 1   
#          }
#          #          run.update({
#          #                                  :command_json => h_cmd.to_json,
#          #                                  :status_id => 1
#          #                                })
#          Basic.upd_run project, run, h_upd, true

          # set run
          
          h_run_attrs = JSON.parse(run.attrs_json)
          h_res = Basic.get_std_method_attrs(std_method, find_marker_step)
          h_attrs = h_res[:h_attrs]
          #    @h_global_params = h_res[:h_global_params]
          
          h_p = {
            :project => project,
            :h_cmd_params => h_cmd_params,
            :run => run,
            :p => h_run_attrs, #list_of_runs2[run_i][1],
            :h_attrs => h_attrs,
            :step => find_marker_step,
            :h_data_classes => h_data_classes,
            :std_method => std_method,
            :h_env => h_env,
            :h_annots => {meta.id => meta, matrix.id => matrix},
            :el_time => t,
            :user_id => user_id #(current_user) ? current_user.id : 1
          }
          h_res = Basic.set_run(logger, h_p)
          #          #          if !h_res[:error]
          #          #
          #          #            run.update({
          #          #                                    :status_id => 1                                   
          #          #                                  })
          #          #          
          #          #          end

          ### need to add the children
          children_runs_raw = Basic.safe_parse_json(matrix_run.children_run_ids, [])
          children_runs = if children_runs_raw.is_a?(Array)
                            children_runs_raw
                          elsif children_runs_raw.nil?
                            []
                          else
                            [children_runs_raw]
                          end
          children_runs.push(run.id) unless children_runs.include?(run.id)
          matrix_run.update_attribute(:children_run_ids, children_runs.to_json)
          
        end
      end

      return {:run => run}

    end
    
    def recursive_parse_hca list_fields, h_data, h_cur, h_project_sum_matrices
      
      #   while (list_fields.include? k) do                                                                                                                                                                                    
      
      if h_data.is_a? Hash
        k = h_data.keys.first
        if h_data[k] and list_fields.include? k
          h_data[k].keys.each do |v|
            h_cur[k] = v
            recursive_parse_hca list_fields, h_data[k][v], h_cur, h_project_sum_matrices
          end
        end
      elsif h_data.is_a? Array
        h_data.each do |f|
          if f['format'] == 'loom'
            if ! h_project_sum_matrices[f['uuid']]
              h_project_sum_matrices[f['uuid']] = {
                :name => f['name'],
                :species => [h_cur['genusSpecies']],
                :organs => [h_cur['organ']],
                :development_stages => [h_cur['developmentStage']],
                :approaches => [h_cur['libraryConstructionApproach']],
                :url => f['url']
              }
            else
              l = [[:species, 'genusSpecies'],
                   [:organs, 'organ'],
                   [:development_stages, 'developmentStage'],
                   [:approaches, 'libraryConstructionApproach']]
              l.each do |e|
                h_project_sum_matrices[f['uuid']][e[0]].push h_cur[e[1]] if !h_project_sum_matrices[f['uuid']][e[0]].include? h_cur[e[1]]
              end
            end
          end
        end
      end
      
      return {
        #:h_data => h_data                                                                                                                                                                                                     
        :h_project_sum_matrices => h_project_sum_matrices
      }
    end

    def move_to_parent_dir source_dir
    
      parent_directory = File.expand_path('..', source_dir)
      # Use FileUtils.mv to move the contents
      FileUtils.mv(Dir.glob(File.join(source_dir, '*')), parent_directory)
      
      # Now, you can remove the empty source directory if needed
      FileUtils.rmdir(source_dir)
      
    end

    def convert_other_formats file_path, logger
      
      init_file_path = file_path
      type = nil
      logger.debug("INIT_PATH:" + file_path.to_s)
      base_dir = file_path.parent()
      tmp_file_path = base_dir + 'input_file'
      input_dir = base_dir + 'input_files'

      # v8 preparsing materializes MTX triplets under fus/<fu_id>/input_file/, and the
      # project root exposes that directory via a symlink named `input_file`. It is
      # also possible for the caller (parse.rake) to pass the pre-extracted bundle
      # path directly. In either case the archive/compression pipeline below has
      # nothing to do and would fail because the "input file" is really a directory.
      # Detect the pre-extracted MTX bundle and jump straight to the MTX->H5
      # conversion using the existing directory.
      resolved_input_path = File.exist?(file_path.to_s) ? Pathname.new(File.realpath(file_path.to_s)) : nil
      if resolved_input_path && resolved_input_path.directory? && (resolved_input_path + 'matrix.mtx').file?
        logger.debug("PRE_EXTRACTED_MTX_BUNDLE: " + resolved_input_path.to_s)
        h5_file_path = base_dir + 'input.h5'
        cmd = "#{asap_run_docker_cmd_prefix('v7')} 'Rscript --vanilla /srv/mtx_to_h5.R #{resolved_input_path} #{h5_file_path}'"
        logger.debug("CMD_CONVERT:" + cmd)
        `#{cmd}`
        if File.exist?(h5_file_path) && File.size(h5_file_path) > 0
          logger.debug("FINAL_PATH:" + h5_file_path.to_s)
          return { :file_path => h5_file_path, :type => 'MEX' }
        end
        write_parsing_output_json_displayed_error(
          base_dir,
          logger,
          [
            'Incomplete Matrix Market (MTX) for v7 conversion.',
            'The pre-extracted bundle contains matrix.mtx but mtx_to_h5.R did not produce input.h5. Check barcodes.tsv and features.tsv (or genes.tsv) next to matrix.mtx, or use parsing with version 8 or later.'
          ]
        )
        raise "MTX to H5 conversion failed for pre-extracted bundle at #{resolved_input_path}"
      end

      if skip_legacy_archive_pipeline_for_v7_h5_matrix?(file_path.to_s)
        kind = legacy_archive_skip_type_for_v7(file_path)
        logger.debug("V7_SKIP_LEGACY_ARCHIVE_PIPELINE: input already HDF5 (#{kind}) at #{file_path}")
        return { :file_path => file_path, :type => kind }
      end

      # Single-file Matrix Market (coordinate/array): the v7 image already ships mtx_to_h5.R,
      # which expects matrix.mtx + barcodes.tsv + features.tsv. No new R script or image
      # rebuild: stage a minimal bundle under the project dir, then call the same R entrypoint.
      mtx_src = first_matrix_market_source_path_for_conversion(file_path, base_dir)
      if mtx_src
        h5_file_path = base_dir + 'input.h5'
        bundle_dir = base_dir + 'coordinate_mtx_bundle_for_h5'
        nrow = nil
        ncol = nil
        begin
          nrow, ncol = matrix_market_row_col_counts(mtx_src)
        rescue StandardError => e
          write_parsing_output_json_displayed_error(
            base_dir,
            logger,
            [
              'Incomplete or invalid Matrix Market (MTX) for v7 conversion.',
              "Could not read matrix dimensions from the file header: #{e.message}"
            ]
          )
          raise
        end
        if nrow <= 0 || ncol <= 0
          write_parsing_output_json_displayed_error(
            base_dir,
            logger,
            [
              'Incomplete Matrix Market (MTX) for v7 conversion.',
              "Invalid dimensions read from the file: #{nrow} rows x #{ncol} columns."
            ]
          )
          raise ArgumentError, "Invalid Matrix Market dimensions nrow=#{nrow}, ncol=#{ncol} for #{mtx_src}"
        end

        FileUtils.rm_rf(bundle_dir) if File.exist?(bundle_dir.to_s)
        FileUtils.mkdir_p(bundle_dir)
        begin
          dest_mtx = (bundle_dir + 'matrix.mtx').to_s
          if matrix_market_file_gzip_compressed?(mtx_src)
            Zlib::GzipReader.open(mtx_src.to_s) do |gz|
              File.open(dest_mtx, 'wb') { |out| IO.copy_stream(gz, out) }
            end
          else
            FileUtils.cp(mtx_src, dest_mtx)
          end
          File.write((bundle_dir + 'features.tsv').to_s, (1..nrow).map { |i| "Gene_#{i}" }.join("\n") + "\n")
          File.write((bundle_dir + 'barcodes.tsv').to_s, (1..ncol).map { |i| "Cell_#{i}" }.join("\n") + "\n")

          cmd = "#{asap_run_docker_cmd_prefix('v7')} 'Rscript --vanilla /srv/mtx_to_h5.R #{bundle_dir} #{h5_file_path}'"
          logger.debug("STAGED_COORDINATE_MTX_TO_H5_CMD: #{cmd}")
          `#{cmd}`
          if File.exist?(h5_file_path) && File.size(h5_file_path).to_i > 0
            logger.debug("FINAL_PATH:" + h5_file_path.to_s)
            return { :file_path => h5_file_path, :type => 'MEX' }
          end
          write_parsing_output_json_displayed_error(
            base_dir,
            logger,
            [
              'Incomplete Matrix Market (MTX) for v7 conversion.',
              'This file is Matrix Market coordinate or array format without barcodes.tsv and features.tsv. ASAP synthesized Gene_* and Cell_* labels and ran mtx_to_h5.R, but no input.h5 was produced.',
              'Upload a full 10x-style bundle (matrix.mtx with barcodes and features) in one folder or archive, or use parsing with version 8 or later.'
            ]
          )
          raise "mtx_to_h5.R did not produce a non-empty file at #{h5_file_path} (staged bundle from coordinate Matrix Market at #{mtx_src})"
        ensure
          FileUtils.rm_rf(bundle_dir) if File.exist?(bundle_dir.to_s)
        end
      end

      if File.exist? input_dir
        FileUtils.rm_r input_dir
      end
      # Avoid self-copy when the canonical input already is `input_file`.
      source_path = File.expand_path(file_path.to_s)
      target_path = File.expand_path(tmp_file_path.to_s)
      same_source_and_target = source_path == target_path
      if !same_source_and_target && File.exist?(file_path.to_s) && File.exist?(tmp_file_path.to_s)
        same_source_and_target = File.identical?(file_path.to_s, tmp_file_path.to_s)
      end
      FileUtils.cp(file_path, tmp_file_path) unless same_source_and_target
      logger.debug("CONVERT_TO_MTX")
      ## check if the file is a zip or tar.gz file
      # cmd = "unzip"
      z_file_path = base_dir + 'input_file.gz'
      `mv #{tmp_file_path} #{z_file_path}`
      cmd = "gunzip #{z_file_path}"
      `#{cmd}`
      if !File.exist? tmp_file_path
        `mv #{z_file_path} #{tmp_file_path}`
        #if File.exist?(file_path)                                                                                                                           
        z_file_path = base_dir + 'input_file.bz2'
        `mv #{tmp_file_path} #{z_file_path}`
        cmd = "bunzip2 #{z_file_path}"
        `#{cmd}`
        if !File.exist? tmp_file_path
          `mv #{z_file_path} #{tmp_file_path}`
          Dir.mkdir input_dir
          z_file_path = input_dir + 'input_file.zip'
          `cp #{tmp_file_path} #{z_file_path}`
          Dir.chdir(input_dir) do
            cmd = "unzip input_file.zip"
            `#{cmd}`
          end
          ### check if there are some other files in the directory                                                                                                                                                        
          logger.debug("input_dir! " + input_dir.to_s)
          files = Dir.entries(input_dir).select{|e| e != "input_file.zip" and !e.match(/^\./)}
          if files.size == 0
            File.delete z_file_path
            logger.debug("move #{z_file_path.to_s} #{tmp_file_path.to_s}")
            Dir.rmdir(input_dir)
          else
            File.delete z_file_path
          end
        end
      end
      
      ## try to untar
      if !File.exist? input_dir
        Dir.mkdir input_dir
        `cp #{tmp_file_path} #{input_dir + 'input_file.tar'}`
        Dir.chdir input_dir do
          `tar -xvf #{tmp_file_path}`
        end
      end
      
      
      
      dirs = Dir.entries(input_dir).select{|e| f = input_dir + e; File.directory?(f) and !e.match(/^\./)}
      files = Dir.entries(input_dir).select{|e| f = input_dir + e; !File.directory?(f) and !e.match(/^\./)}
      logger.debug("DIR: " + dirs.to_json)
      logger.debug("FILES2:" + files.to_json)
      mtx_files = files.select{|e| e.match(/\.mtx$/)} 
      
      ## deal with the case of 1 sub-folder (https://cf.10xgenomics.com/samples/cell/pbmc3k/pbmc3k_filtered_gene_bc_matrices.tar.gz)
      if files.size == 1 and dirs.size == 1
        d = dirs.first
        sub_dirs = Dir.entries(input_dir + d).select{|e| f = input_dir + d + e; File.directory?(f) and !e.match(/^\./)}
        sub_files =  Dir.entries(input_dir + d).select{|e| f = input_dir + d + e; !File.directory?(f)}
        logger.debug("DIR2: " + dirs.to_json)
        if sub_files.size == 0 and sub_dirs.size == 1
          logger.debug("DIR3: " + sub_dirs.to_json)
          #          FileUtils.mv input_dir + d + sub_dirs.first, input_dir + d 
          move_to_parent_dir(input_dir + d + sub_dirs.first)
        end
      end
      
      logger.debug("files:" + files.size.to_s + ", mtx_files: " + mtx_files.to_json)
      
      if files.size > 2 and (mtx_files.size == 1 or files.include?("matrix.mtx"))
        File.delete tmp_file_path
        File.delete input_dir + "input_file.tar" if File.exist?(input_dir + "input_file.tar")
        #           File.delete input_dir + "input_file.zip" if File.exist?(input_dir + "input_file.zip")                                                                                    
        logger.debug("cTEST1"  +  files.to_json)
      elsif dirs.size >0 #and files.size == 0
        dirs.each do |d|
          if Dir.entries(input_dir + d).select{|e| e.match(/\.mtx$/)}.size == 1 or Dir.entries(input_dir + d).include?("matrix.mtx")
            logger.debug("cTEST2: " + [input_dir + d, input_dir].to_json)
            Dir.entries(input_dir + d).select{|e| f = input_dir + d + e; !File.directory?(f) and !e.match(/^\./)}.each do |f|
              FileUtils.move input_dir + d + f, input_dir
            end
            Dir.rmdir input_dir + d
            #`mv #{(input_dir + d).to_s}/* #{input_dir}`
            logger.debug("cTEST2")
          end
        end
        
        
        
        # elsif files.size == 1
        #   FileUtils.move input_dir + files.first, tmp_file_path
        #   FileUtils.rm_r input_dir if File.exist? input_dir
        #   logger.debug("cTEST3")
        # else
        #   File.delete input_dir + "input_file.tar" if File.exist?(input_dir + "input_file.tar")
        #   FileUtils.rm_r input_dir if File.exist? input_dir
        #   #              Dir.rmdir input_dir if File.exist? input_dir       
        #   logger.debug("cTEST4")                   
      end
      
      ### if input_dir exists then apply the conversion
      h5_file_path = base_dir + 'input.h5'
      
      ## rename mtx file if only one
      mtx_files = Dir.entries(input_dir).select{|e| e.match(/\.mtx$/)}
      
      if mtx_files.size == 1
        if !File.exist? input_dir + 'matrix.mtx'
          FileUtils.mv input_dir + mtx_files.first, input_dir + 'matrix.mtx'
        end
      end
      
      if File.exist? input_dir and File.exist? input_dir + 'matrix.mtx'     
        cmd = "#{asap_run_docker_cmd_prefix('v7')} 'Rscript --vanilla /srv/mtx_to_h5.R #{input_dir} #{h5_file_path}'"
        logger.debug("CMD_CONVERT:" + cmd)
        `#{cmd}`
        if File.exist? h5_file_path and File.size(h5_file_path) > 0
          file_path = h5_file_path
          type = 'MEX'
        end
      end
      
      if init_file_path == file_path && File.exist?(input_dir.to_s) && File.directory?(input_dir.to_s)
        extracted_entries = Dir.entries(input_dir).reject { |e| e.start_with?('.') || e == 'input_file.tar' || e == 'input_file.zip' }
        h5_entries  = extracted_entries.select { |e| e.match(/\.h5$/i) && File.file?(input_dir + e) }
        h5ad_entries = extracted_entries.select { |e| e.match(/\.h5ad$/i) && File.file?(input_dir + e) }
        loom_entries = extracted_entries.select { |e| e.match(/\.loom$/i) && File.file?(input_dir + e) }
        if h5ad_entries.size >= 1
          extracted_h5ad = input_dir + h5ad_entries.first
          dest = base_dir + h5ad_entries.first
          FileUtils.cp(extracted_h5ad.to_s, dest.to_s)
          file_path = dest
          type = 'H5AD'
          logger.debug("EXTRACTED_H5AD_FROM_ARCHIVE: #{file_path}")
        elsif h5_entries.size >= 1
          extracted_h5 = input_dir + h5_entries.first
          FileUtils.cp(extracted_h5.to_s, h5_file_path.to_s)
          file_path = h5_file_path
          type = 'MEX'
          logger.debug("EXTRACTED_H5_FROM_ARCHIVE: #{file_path}")
        elsif loom_entries.size >= 1
          extracted_loom = input_dir + loom_entries.first
          dest = base_dir + 'input.loom'
          FileUtils.cp(extracted_loom.to_s, dest.to_s)
          file_path = dest
          type = 'LOOM'
          logger.debug("EXTRACTED_LOOM_FROM_ARCHIVE: #{file_path}")
        end
      end

      logger.debug("#{init_file_path} == #{file_path}")
      
      if init_file_path == file_path
     
        ## check if it's a rds file
        if file_path.to_s.match(/\.rds$/)
          ##try to convert
          logger.debug("TRY RDS CONVERSION")
          loom_file_path = base_dir + 'input.loom'
          cmd = "#{asap_run_docker_cmd_prefix('v7')} 'Rscript --vanilla /srv/convert_seurat.R #{file_path.to_s} #{loom_file_path}'"
          logger.debug("CMD RDS: #{cmd}")
          `#{cmd}`
          if File.exist? loom_file_path
            file_path = loom_file_path
            type = 'RDS'
          end
        end
        
      end

      # gunzip removes input_file.gz and leaves base_dir/input_file, but file_path
      # often still points at the original Pathname (e.g. .../input_file.gz). Callers
      # and re-parses must see the path that actually exists on disk.
      if !File.exist?(file_path.to_s) && File.exist?(tmp_file_path.to_s)
        file_path = tmp_file_path
        logger.debug("LEGACY_INPUT: using existing #{file_path} after decompress (original path missing)")
      end

      logger.debug("FINAL_PATH:" + file_path.to_s)
      return {:file_path => file_path, :type => type}
    end

     def sql_query3 version, model, select, where

      h = {
        :model => model,
        :select => select,
        :where => where
      }

      cmd = "RAILS_ENV=data_v#{versiom.to_s} && echo '#{t.to_json}' | rails -q get_data"
      res = `#{cmd}`
      res.split("\n").each do
      end
      return
    end

    
    def sql_query2 type, version, from, join, select, where
      require 'ostruct'
      version ||= ''

      where||='1=1'
      #      query = model.select(select).joins(join).where(where).to_sql.gsub("'", "\\\\'")
      query = "select #{select} from #{from} #{join} where #{where}" #.gsub("'", "\\\\'")
#      puts query
      asap_data_host = ENV.fetch('ASAP2_REMOTE_HOST', 'host.docker.internal')
      asap_data_port = ENV.fetch('ASAP2_REMOTE_PORT', '5433')
      h_cmd = {
        :asap_development => "psql -h postgres -p 5434 -U postgres -AF $'<\t>' --no-align -c \"#{query}\" asap2_development",
        :asap_data => "psql -h #{asap_data_host} -p #{asap_data_port} -U postgres -AF $'<\t>' --no-align -c \"#{query}\" asap_data_v#{version}"
      }
      
 
      cmd = h_cmd[type]
      output = `#{cmd}`
      res = []
      headers = []
      flag = 0
      t = output.split("\n")
        (0 .. t.size-2).each do |i|        
        if i == 0
          t[i].split("<\t>").each do |e|
            headers.push e
          end
        else
          h_data = {}
          t2 = t[i].split("<\t>")
          t2.each_index do |j|
            h_data[headers[j]] = t2[j]
          end
          res.push OpenStruct.new(h_data)
        end
      end
      return res 
    end      
    
    def sql_query shard, model, select, where
      
      res = nil
      
      begin
        
        # Get the hash (i.e. parsed) representation of database.yml
        databases = Rails.configuration.database_configuration
        
        # Get a fancier AR-specific version of this hash, which is actually a wrapper of the hash
        resolver = ActiveRecord::ConnectionAdapters::ConnectionSpecification::Resolver.new(databases)
        
        # Get one specific database from our list of databases in database.yml. pick any database identifier (:development, :user_shard1, etc)
        spec = resolver.spec(shard)

        # Make a new pool for the database we picked
        pool = ActiveRecord::ConnectionAdapters::ConnectionPool.new(spec)
        
        # Use the pool
        # This is thread-safe, ie unlike ActiveRecord's establish_connection, it won't leak to other threads
        pool.with_connection { |conn|
          
          # Now we can perform direct SQL commands
         # result = conn.execute('select count(*) from users') # result will be an array of rows
         # puts result.first
          
          # We can make AR queries using to_sql
          # See http://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/DatabaseStatements.html
          sql = model.select(select).where(where).to_sql # generate SQL string
          res = conn.select_all sql # get list of hashes, one hash per matching result
          
        }
        
      rescue => ex
        puts ex, ex.backtrace
      ensure
        pool.disconnect!
      end
      
      return res
    end
    
    
    def set_predict_params p, run, std_method, h_runs, h_steps
      
      project_dir =  Pathname.new(ENV.fetch('USER_DATA_DIR')) + p.user_id.to_s + p.key
      
      h_predict_params = {}
      
      if run.std_method_id #and run.std_method_id == 25                                                                                                            
        puts "RUN: #{run.id}"
        h_command = Basic.safe_parse_json(std_method.command_json, {})
        h_attrs = {}
        h_run_attrs = Basic.safe_parse_json(run.attrs_json, {})
        puts h_run_attrs.to_json
        if h_command['predict_params']
          h_command['predict_params'].select{|e| e != 'std_method_name' and h_run_attrs[e]}.each do |e|
            h_predict_params[e] = h_run_attrs[e]
          end
        end
        
        #puts h_run_attrs.to_json                                                                                                                                  
        #{"input_matrix":{"run_id":14078,"output_attr_name":"output_matrix","output_filename":"cell_filtering/14078/output.loom","output_dataset":"/matrix"},"fdr":"0.1","min_disp":"0.5"}                                                                  
        input_matrix_run = nil
        ['input_matrix', 'input_de'].each do |e|
          puts "H_RUN_ATTRS:" + h_run_attrs.to_json
          if h_run_attrs[e] and  input_matrix = ((h_run_attrs[e].is_a? Array) ? h_run_attrs[e][0] : h_run_attrs[e]) and input_matrix['run_id']
            puts input_matrix.to_json
            input_matrix_run = h_runs[input_matrix["run_id"].to_i]
          end
        end

        puts "H_STEPS: " + h_steps.to_json
        if h_steps[run.step_id].name != 'parsing'
          #   h_attrs['nber_cols'] = p.nber_cols.to_i
          #   h_attrs['nber_rows'] = p.nber_rows.to_i
          # else
          
#          input_matrix_run = nil
#          ['input_matrix', 'input_de'].each do |e|
#          input_matrix_run = h_runs[h_run_attrs[e]["run_id"].to_i] if h_run_attrs[e] and h_run_attrs[e]["run_id"]
#          end
                    
          if input_matrix_run
            run_dir = project_dir + h_steps[input_matrix_run.step_id].name
            run_dir += input_matrix_run.id.to_s if h_steps[input_matrix_run.step_id].multiple_runs == true #) ? (local_step_dir + a.run_id.to_s) : local_step_dir)  
            output_file = run_dir + 'output.json'
            h_tmp = {}
            if File.exist? output_file
              h_tmp = Basic.safe_parse_json(File.read(output_file), {})
            end
            
            h_tmp.each_key do |k|
              h_attrs[k] = h_tmp[k]
            end
            
            ['nber_cols', 'nber_rows'].each do |k|
              if !h_attrs[k] and h_attrs['metadata']
                if h_attrs['metadata'][0]
                  h_attrs[k] =h_attrs['metadata'][0][k].to_i
                else
                  puts h_attrs['metadata'].to_json
                end
              end
            end
            
          end
        end
        
        if h_command['predict_params']
          h_command['predict_params'].reject{|e| e == 'std_method_name'}.each do |e|
            h_predict_params[e] = h_attrs[e] if h_attrs[e]
          end
        end
      end
      return h_predict_params
      
    end
    
    def get_run_stats version
      asap_docker_image = get_asap_docker(version)
      h_run_stats = {}
      #project_ids = Project.select("id").where(:version_id => version.id).all
      
      #      StdMethod.where(:version_id => version.id).all.each do |s|
      StdMethod.where(:docker_image_id => asap_docker_image.id
                      ).all.each do |s| 
        h_run_stats[s.id] = {
          :pred_params => Basic.safe_parse_json(s.command_json, {})['predict_params'],
          :std_method_name => s.name,
          :runs => []
        }
      end
      
      all_runs = Run.joins(:project).where(:projects => {:version_id => version}, :std_method_id => h_run_stats.keys).all.reject{|r| r.process_duration == 0} + #and [1, 20].include?(r.step_id)} +
        DelRun.joins(:project).where(:projects => {:version_id => version}, :std_method_id => h_run_stats.keys).all.reject{|r| r.process_duration == 0}# and [1, 20].include?(r.step_id)}
      
      all_runs.each do |r|
        if h_run_stats[r.std_method_id]
          #          puts r.to_json
          #          exit
          # h_run_stats[r.std_method_id] ||= {:runs => [], :predict_params => }                                                                                   
          h_tmp = {:id => r.id, :t => r.process_duration, :m => r.max_ram, :c => r.nber_cores || 1}
          h_predict_params = Basic.safe_parse_json(r.pred_params_json, {})
          if  h_predict_params.keys.size > 0
            h_predict_params.each_key do |k|
              h_tmp[k] = (['nber_cols', 'nber_rows'].include? k) ?  h_predict_params[k].to_i : h_predict_params[k]
            end
            if h_tmp['nber_cols'] and h_tmp['nber_rows'] and h_tmp['nber_cols'] != 0 and h_tmp['nber_rows'] != 0
              h_run_stats[r.std_method_id][:runs].push(h_tmp)
            end
          end
        end
      end
      
      list = []
      h_run_stats.each_key do |sid|
        h_tmp =  h_run_stats[sid]
        h_tmp[:std_method_id] = sid
        list.push h_tmp
      end
      
      return list
    end

    def safe_parse_json json, default
      h = default
      begin
        h = JSON.parse json
      rescue
      end
      return h
    end

    # Extract JSON object(s) printed to stdout by pipeline scripts (R, parse.v8.py).
    def json_objects_from_command_output(output)
      return [] if output.blank?

      objects = []
      output.to_s.each_line do |line|
        line = line.strip
        next if line.empty?

        next unless line.start_with?('{') || line.start_with?('[')

        begin
          objects << JSON.parse(line)
        rescue JSON::ParserError
          # ignore non-JSON lines
        end
      end
      objects
    end

    def integration_r_result_from_output(r_output)
      json_objects_from_command_output(r_output).reverse.find do |obj|
        obj.is_a?(Hash) && (obj.key?('nber_rows') || obj.key?('displayed_error'))
      end
    end

    def parse_result_from_command_output(parse_output)
      json_objects_from_command_output(parse_output).reverse.find do |obj|
        obj.is_a?(Hash) && (obj.key?('nber_rows') || obj.key?('displayed_error'))
      end
    end

    def loom_has_main_matrix?(loom_path, image_name:)
      return false unless File.exist?(loom_path)

      require 'shellwords'
      script = "import h5py,sys; f=h5py.File(sys.argv[1],'r'); sys.exit(0 if 'matrix' in f else 1)"
      mount = user_data_docker_volume_mount_arg
      cmd = [
        'docker run --rm',
        mount,
        '--entrypoint python3',
        image_name,
        '-c',
        Shellwords.escape(script),
        Shellwords.escape(loom_path.to_s)
      ].join(' ')
      system(cmd)
      $?.success?
    end

    def integration_project?(h_attrs)
      h = h_attrs.is_a?(Hash) ? h_attrs : safe_parse_json(h_attrs.to_s, {})
      h['integrate_method'].present? || h['integrate_batch_paths'].present?
    end

    def integration_source_keys(h_attrs)
      h = h_attrs.is_a?(Hash) ? h_attrs : safe_parse_json(h_attrs.to_s, {})
      if h['integrate_source_keys'].present?
        Array(h['integrate_source_keys']).map(&:to_s).reject(&:blank?)
      elsif h['integrate_batch_paths'].is_a?(Hash)
        h['integrate_batch_paths'].keys.map(&:to_s).reject(&:blank?)
      else
        []
      end
    end

    def integration_method_label(h_attrs)
      h = h_attrs.is_a?(Hash) ? h_attrs : safe_parse_json(h_attrs.to_s, {})
      method_key = h['integrate_method'].presence || 'harmony'
      Basic::INTEGRATION_METHOD_LABELS[method_key.to_s] || method_key.to_s.capitalize
    end

    def broadcast_integration_status(project, stage, source_key: nil, error: nil)
      payload = {
        project_id: project.id,
        integration_status: stage.to_s
      }
      payload[:integration_source_key] = source_key if source_key.present?
      payload[:integration_error] = error.to_s if error.present?
      ActionCable.server.broadcast("project_#{project.id}", payload)
    end

    def integration_batch_levels_error_message
      'Batch correction requires at least two distinct batch levels. The selected batch metadata has only one value in one or more source projects (for example donor_id is "pooled" everywhere). Choose "None" to treat each project as its own batch, or pick a metadata column with multiple categories.'
    end

    def integration_command_error_message(output, context: 'Integration')
      result = integration_r_result_from_output(output)
      if result && result['displayed_error'].present?
        err = result['displayed_error']
        return err.is_a?(Array) ? err.join(' ') : err.to_s
      end

      text = output.to_s
      if text.include?('contrasts can be applied only to factors with 2 or more levels')
        return integration_batch_levels_error_message
      end

      if (m = text.match(/Error in[^:\n]*:\s*(.+)/))
        return m[1].strip
      end

      tail = text.strip.split("\n").reject(&:blank?).last(2).join(' ')
      tail.presence || "#{context} failed"
    end

    def integration_user_error_message(message)
      msg = message.to_s.sub(/\A\[IntegrateRake\]\s*/, '')
      return integration_batch_levels_error_message if msg.include?('contrasts can be applied only to factors with 2 or more levels')

      if (m = msg.match(/R integration exited with status \d+\.\s*(.+)/m))
        inner = m[1].strip
        return integration_batch_levels_error_message if inner.include?('contrasts can be applied only to factors with 2 or more levels')
        if (em = inner.match(/Error in[^:\n]*:\s*(.+)/))
          return em[1].strip
        end
        return inner.lines.first.to_s.strip.presence || msg
      end

      msg
    end
        
    # Show the average system load of the past minute
    def machine_load
      load = 0.0
      if File.exist?("/proc/loadavg")
        File.open("/proc/loadavg", "r") do |file|
          @loaddata = file.read
        end
        
        load = @loaddata.split(/ /).first.to_f
      end
    
      return load
    end

    def unarchive k, progress_callback: nil
      require 'shellwords'

      p = Project.find_by_key(k)
      return false unless p

      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + p.user_id.to_s + p.key
      return true if p.archive_status_id == 1 && File.exist?(project_dir)

      begin
        h_s3_settings = get_s3_settings()
        s3b = {
          :key => '20000-af8a16d143d9920a26869b30700c3da4',
          :endpoint => 'https://s3.epfl.ch',
          :region => 'us-west-2'
        }
        s3 = connect_s3(s3b, h_s3_settings)

        p.update_archive_metadata!(archive_status_id: 4)
        user_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + p.user_id.to_s
        FileUtils.mkdir_p(user_dir) unless File.exist?(user_dir)

        project_archive = "#{p.key}.tgz"
        filepath = user_dir + project_archive

        progress_callback.call('retrieving') if progress_callback
        if !File.exist?(filepath) || File.size(filepath).to_i == 0
          File.delete(filepath) if File.exist?(filepath) && File.size(filepath).to_i == 0

          downloaded = false
          3.times do
            downloaded = write_file_from_s3(s3, s3b[:key], p, filepath)
            break if downloaded && File.exist?(filepath) && File.size(filepath).to_i > 0
            sleep 2
          end

          unless downloaded && File.exist?(filepath) && File.size(filepath).to_i > 0
            p.update_archive_metadata!(archive_status_id: 3)
            return false
          end
        end

        progress_callback.call('unpacking') if progress_callback
        cmd = "cd #{Shellwords.escape(user_dir.to_s)} && pigz -p 32 -dc #{Shellwords.escape(project_archive)} | tar -xv"
        puts "CMD: #{cmd}"
        `#{cmd}`
        extraction_ok = $?.success? && File.exist?(project_dir) && `du -s #{Shellwords.escape(project_dir.to_s)}`.to_i > 10

        unless extraction_ok
          p.update_archive_metadata!(archive_status_id: 3)
          return false
        end

        File.delete(filepath) if File.exist?(filepath)
        p.update_archive_metadata!(archive_status_id: 1, disk_size_archived: nil)
        true
      rescue => e
        Rails.logger.error("[Basic.unarchive] #{e.class}: #{e.message}")
        p.update_archive_metadata!(archive_status_id: 3) if p
        false
      end
    end
    
    def relative_path project, path
      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
  #    puts project_dir + " -- " + path
  #    return path.relative_path_from(project_dir)
      return path.to_s.gsub(/^#{project_dir}\//, "")
    end

    def std_method_project_type_compatible?(project, std_method: nil, obj_attrs: nil)
      obj_attrs ||= safe_parse_json(std_method&.obj_attrs_json, {})
      project_types = Array(obj_attrs['project_types'])
      return true if project_types.empty?

      project_type_tag = project&.project_type&.tag
      project_type_name = project&.project_type&.name
      project_types.include?(project_type_name) ||
        (project_type_tag.present? && project_types.include?(project_type_tag))
    end

    # Walk default_std_method names in order; skip methods unavailable for this project type.
    def resolve_default_std_method(project:, default_method_names:, std_methods_by_name:, h_obj_attrs_by_std_method: {}, available_methods: nil)
      Array(default_method_names).each do |name|
        method = std_methods_by_name[name]
        next unless method
        next if available_methods && !available_methods.include?(method)

        obj_attrs = h_obj_attrs_by_std_method[method.id] || safe_parse_json(method.obj_attrs_json, {})
        next unless std_method_project_type_compatible?(project, obj_attrs: obj_attrs)

        return method
      end
      nil
    end

    def get_std_method_attrs std_method, step
      
      h_global_params = JSON.parse(step.method_attrs_json)
      
      h_attrs = (std_method) ? JSON.parse(std_method.attrs_json) : {}
      ## complement attributes with global parameters - defined at the level of the step                                                      
    #  puts h_attrs.to_json
     # puts h_global_params.to_json
      h_global_params.each_key do |k|
     #   puts "->k: #{k}"
        puts h_attrs.to_json
       #flag = 0
       # if !h_attrs[k]
#       #   puts "#{std_method.id}-> k #{k} OK"
        #else
        #  flag = 1
       #   puts "#{std_method.id}-> k #{k} already exist (not changed): #{h_attrs[k].to_json} => #{h_global_params[k].to_json}!!!!!!!!!!!!!!!!!!!"
       # end
        h_attrs[k]={} if !h_attrs[k]
        h_global_params[k].each_key do |k2|
     #     puts "->k2: #{k2}, #{h_global_params[k][k2]}"
          h_attrs[k][k2] = h_global_params[k][k2] if ! h_attrs[k][k2] 
        end
        
       # if flag== 1
       #   puts "!!!!!!!!!!!!!!Result =>" + h_attrs[k].to_json
       # end
        
      end
      
      h_res = {
        :h_attrs => h_attrs,
        :h_global_params => h_global_params
      }

      return h_res
    end

    def create_upd_fo project_id, relative_filepath, cache = nil
      cache ||= {}
      store_run_by_key = cache[:store_run_by_key] ||= {}
      fo_by_key = cache[:fo_by_key] ||= {}
      
   #   puts "project_id => #{project_id}, relative_filepath => #{relative_filepath}"
      t = relative_filepath.split("/")
      store_run = nil
      if t.size == 3
        run_lookup_key = [:run_id, t[1].to_i]
        if store_run_by_key.key?(run_lookup_key)
          store_run = store_run_by_key[run_lookup_key]
        else
          store_run = Run.where(:id => t[1]).first
          store_run_by_key[run_lookup_key] = store_run
        end
      else
        run_lookup_key = [:project_step_name, project_id, t[0]]
        if store_run_by_key.key?(run_lookup_key)
          store_run = store_run_by_key[run_lookup_key]
        else
          store_run = Run.joins("join steps on (step_id = steps.id)").where(:project_id => project_id, :steps => {:name => t[0]}).first
          store_run_by_key[run_lookup_key] = store_run
        end
      end

      if store_run
        project = store_run.project
        
        h_fo = {
          :project_id => store_run.project_id,
          :run_id => store_run.id,
          :user_id => store_run.user_id,
          :filepath => relative_filepath,
          :ext => relative_filepath.split(".").last
        }
        fo_cache_key = [h_fo[:project_id], h_fo[:run_id], h_fo[:user_id], h_fo[:filepath], h_fo[:ext]]
        if fo_by_key.key?(fo_cache_key)
          fo = fo_by_key[fo_cache_key]
        else
          fo = Fo.where(h_fo).first
          if !fo
            fo = Fo.new(h_fo)
            fo.save
          end
          fo_by_key[fo_cache_key] = fo
          
          project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
          filepath = project_dir + fo.filepath
          fo.update(:filesize => File.size(filepath))
        end
      end

      return fo
    end

    def  add_cell_sets p, project_dir, a, meta_compl, list_cats, cache = nil
      cache ||= {}
      h_cell_sets = cache[:cell_sets_by_md5] ||= {}
      h_cell_set_by_cat_idx = {}
      pc = p.project_cell_set
      cell_ids_file = project_dir + 'parsing' + 'cell_ids'
      stable_ids_file = project_dir + (a.filepath + ".stable_ids")
      if !pc
        puts "ERROR! Project #{p.id} has no project_cell_set associated to it"
        project_cell_set = ProjectCellSet.where(:id => p.project_cell_set_id).first
        puts "PROJECT: " + p.to_json
        puts "PROJECT2: " + Project.where(:key => p.key).first.to_json
        puts "PROJECT_CELL_SET: " + project_cell_set.to_json
      elsif File.exist?(stable_ids_file) and File.exist?(cell_ids_file)

        cells_cache = cache[:cells_values_by_project_id] ||= {}
        if cells_cache.key?(p.id)
          cells = cells_cache[p.id]
        else
          output = File.read(cell_ids_file)
          res =  Basic.safe_parse_json(output,  {})
          cells = res['values']
          cells_cache[p.id] = cells
        end

        stable_ids_cache = cache[:stable_ids_values_by_file] ||= {}
        stable_key = stable_ids_file.to_s
        if stable_ids_cache.key?(stable_key)
          stable_ids = stable_ids_cache[stable_key]
        else
          output = File.read(stable_ids_file)
          res = Basic.safe_parse_json(output,  {})
          stable_ids = res['values']
          stable_ids_cache[stable_key] = stable_ids
        end

        vals = meta_compl['values']
        
        if vals and cells and cells.size > 0 and stable_ids
          if vals.size == stable_ids.size

            ## init annot cell sets

            project_annot_cell_sets_cache = cache[:annot_cell_sets_by_project_id] ||= {}
            if project_annot_cell_sets_cache.key?(p.id)
              h_annot_cell_sets = project_annot_cell_sets_cache[p.id]
            else
              h_annot_cell_sets = {}
              AnnotCellSet.where(:project_id => p.id).all.each do |acs|
                h_annot_cell_sets[[acs.annot_id, acs.cat_idx]] = acs
              end
              project_annot_cell_sets_cache[p.id] = h_annot_cell_sets
            end
            
            h_cells = {}

            ## init categories                                                                                                                                  
            list_cats.each do |cat|
              h_cells[cat] = []
            end
            vals.each_index do |i|
              #    puts vals[i]                                                                                                                                 
              if h_cells[vals[i]] and stable_ids[i]
                # Convert stable_ids[i] to integer if it's a string, to use as array index
                stable_id_idx = stable_ids[i].is_a?(String) ? stable_ids[i].to_i : stable_ids[i]
                h_cells[vals[i]].push cells[stable_id_idx] if cells[stable_id_idx]
              else
                puts "Category #{vals[i]} not found in #{a.name} [#{project_dir + a.filepath}]."
              end
            end
            ## for each category compute hash                                                                                                                   
            #     list_md5 = []                                                                                                                                 
            list_cats.each_index do |cat_idx|
              cat = list_cats[cat_idx]
              # list_md5.push Digest::MD5.hexdigest h_cells[cat].to_json                                                                                        
              md5 = Digest::MD5.hexdigest h_cells[cat].sort.to_json
              
              h_cell_set = {
                :key => md5,
                :project_cell_set_id => pc.id,
                :nber_cells => h_cells[cat].size
              }
              
              #            cell_set = CellSet.where(:key => md5, :project_cell_set_id => pc.id).first                                                           
              cell_set = h_cell_sets[md5]
              if !cell_set
                cell_set = CellSet.where(key: md5, project_cell_set_id: pc.id).first
                h_cell_sets[md5] = cell_set if cell_set
              end
              if !cell_set
                cell_set = CellSet.new(h_cell_set)
                cell_set.save
                h_cell_sets[md5] = cell_set
                puts "Create cell set #{cell_set.id}"
              else
                puts "cell set #{cell_set.id} exists!"
              end
              h_cell_set_by_cat_idx[cat_idx] = cell_set
              
              h_ac = {
                # :cell_set_id => cell_set.id,                                                                                                             
                :project_id => p.id,
                :annot_id => a.id,
                :cat_idx => cat_idx
              }
              #    ac = AnnotCellSet.where(h_ac).first                                                                                                         
              ac = h_annot_cell_sets[[a.id, cat_idx]]
              if !ac
                h_ac[:cell_set_id] = cell_set.id
                ac = AnnotCellSet.new(h_ac)
                ac.save
                h_annot_cell_sets[[a.id, cat_idx]] = ac
                puts "Create annot_cell_set #{ac.id}"
              else
                puts "annot_cell_set #{ac.id} exists!"
                if ac.cell_set_id != cell_set.id
                  ac.update!(cell_set_id: cell_set.id)
                  puts "Update annot_cell_set #{ac.id} cell_set_id to #{cell_set.id} (category membership changed)"
                end
              end
              
            end
          else
            puts "Stable IDs and metadata have not same sizes (#{stable_ids.size} vs. #{vals.size})"
          end
        else
          puts "Vals (#{vals.to_json}) or cells not there"
        end
      end
      
      return h_cell_set_by_cat_idx
    end

    # Memo key: tax_id -> NcbiTaxonomyNode.order_tax_id_for(tax_id) (may be nil). Pass {} from batch resolvers.
    def ncbi_order_tax_id_for_memo(tid, memo)
      tid = tid.to_i
      return nil unless tid.positive?

      if memo
        return memo[tid] if memo.key?(tid)

        memo[tid] = ::NcbiTaxonomyNode.order_tax_id_for(tid)
      else
        ::NcbiTaxonomyNode.order_tax_id_for(tid)
      end
    end

    def ncbi_taxonomy_nodes_available?
      defined?(::NcbiTaxonomyNode) && ::NcbiTaxonomyNode.table_exists?
    rescue StandardError
      false
    end

    # :exact = ontology tax_ids lists project species; :order = same NCBI order as an anchor (ncbi_taxonomy_nodes);
    # :universal = ontology has no tax_ids restriction; nil = not applicable.
    def cell_ontology_match_tier(term, organism_tax_id, order_tax_id_memo: nil)
      return nil unless term.original == true

      tax_id = organism_tax_id.to_i
      return nil if tax_id <= 0

      ontology = term.cell_ontology
      return :universal unless ontology

      tax_ids = ontology.tax_id_list
      return :universal if tax_ids.empty?

      return :exact if tax_ids.include?(tax_id)

      return nil unless ncbi_taxonomy_nodes_available?

      project_order = ncbi_order_tax_id_for_memo(tax_id, order_tax_id_memo)
      return nil if project_order.blank?

      if tax_ids.any? { |anchor|
        aid = anchor.to_i
        next false unless aid.positive?

        anchor_order = ncbi_order_tax_id_for_memo(aid, order_tax_id_memo)
        anchor_order.present? && anchor_order == project_order
      }
        :order
      else
        nil
      end
    end

    def cell_ontology_term_applicable_to_tax_id?(term, organism_tax_id, order_tax_id_memo: nil)
      tid = organism_tax_id.to_i
      return true if tid <= 0

      !cell_ontology_match_tier(term, organism_tax_id, order_tax_id_memo: order_tax_id_memo).nil?
    end

    # Prefer exact species ontologies, then same-order (e.g. Diptera), then tax-unrestricted ontologies.
    def pick_terms_by_taxonomy_priority(matches, organism_tax_id, order_tax_id_memo)
      return matches if matches.empty?

      exact = []
      order = []
      universal = []

      matches.each do |term|
        case cell_ontology_match_tier(term, organism_tax_id, order_tax_id_memo: order_tax_id_memo)
        when :exact
          exact << term
        when :order
          order << term
        when :universal
          universal << term
        end
      end

      pool = if exact.any?
               exact
             elsif order.any?
               order
             elsif universal.any?
               universal
             else
               matches
             end

      pool.sort_by(&:id)
    end

    # Map metadata category labels to original Cell Ontology terms (one query per distinct label set).
    # Prefer identifier match over name; lowest id wins when several rows share the same identifier or name.
    # Skips obsolete terms and terms in obsolete ontologies (see CellOntologyTerm.with_active_cell_ontology).
    # When organism_tax_id is present: filter by applicability, then exact species > same NCBI order > universal ontology.
    def h_cell_ontology_terms_by_cat_label(labels, organism_tax_id = nil)
      labels = labels.map(&:to_s).uniq.reject(&:empty?)
      return {} if labels.empty?

      terms = ::CellOntologyTerm.original.with_active_cell_ontology
        .where("cell_ontology_terms.identifier IN (?) OR cell_ontology_terms.name IN (?)", labels, labels)
        .includes(:cell_ontology)
        .order(:id)
      if organism_tax_id.present?
        order_memo = {}
        terms = terms.select { |term| cell_ontology_term_applicable_to_tax_id?(term, organism_tax_id, order_tax_id_memo: order_memo) }
        terms = pick_terms_by_taxonomy_priority(terms, organism_tax_id, order_memo)
      end
      by_ident = {}
      by_name = {}
      terms.each do |term|
        by_ident[term.identifier] ||= term if term.identifier.present?
        by_name[term.name] ||= term if term.name.present?
      end
      labels.index_with { |name| by_ident[name] || by_name[name] }
    end

    # Unique OntologyTermType id for the given CellOntologyTerm id(s), or nil when
    # empty / unresolved / ambiguous (see ClaOntologyTermTypeResolver).
    def ontology_term_type_id_for_cot_ids(cot_ids, resolver: nil)
      ClaOntologyTermTypeResolver.ontology_term_type_id_for(cot_ids, resolver: resolver)
    end

    # ASAP auto Clas: create/update only when category label maps to an ontology term.
    # Name stays blank; ontology_term_type_id is set when uniquely resolvable.
    def add_clas project, a, h_cell_sets, cache = nil
      cache ||= {}
      cla_by_annot_cat = cache[:cla_by_annot_cat] ||= {}
      cot_by_name_or_identifier = cache[:cot_by_name_or_identifier] ||= {}
      annot_clas_by_catidx = cache[:annot_clas_by_catidx] ||= {}
      ott_id_by_cot_id = cache[:ott_id_by_cot_id] ||= {}

      list_cats =  Basic.safe_parse_json(a.list_cat_json, [])

      # Resolve ontology terms (see h_cell_ontology_terms_by_cat_label).
      missing_names = list_cats.map(&:to_s).select { |name| name != '' }.uniq.reject { |name| cot_by_name_or_identifier.key?(name) }
      if missing_names.any?
        h_cell_ontology_terms_by_cat_label(missing_names, project&.organism&.tax_id).each do |name, term|
          cot_by_name_or_identifier[name] = term
        end
      end

      # Preload existing clas for this annotation once.
      if !annot_clas_by_catidx.key?(a.id)
        h_existing = {}
        Cla.where(annot_id: a.id).find_each do |existing_cla|
          h_existing[existing_cla.cat_idx] = existing_cla if !existing_cla.cat_idx.nil?
          cla_by_annot_cat[[a.id, existing_cla.cat_idx]] ||= existing_cla if !existing_cla.cat_idx.nil?
        end
        annot_clas_by_catidx[a.id] = h_existing
      end
      existing_clas_for_annot = annot_clas_by_catidx[a.id]

      sel_clas = []
      list_cats.each_index do |i|
        k = list_cats[i]
        annot_name = k
        cot = (annot_name.present?) ? cot_by_name_or_identifier[annot_name.to_s] : nil

        if cot
          cot_ids = cot.id
          unless ott_id_by_cot_id.key?(cot.id)
            ott_id_by_cot_id[cot.id] = ontology_term_type_id_for_cot_ids(cot_ids)
          end
          h_cla = {
            :cla_source_id => ASAP_AUTO_CLA_SOURCE_ID,
            :name => "",
            :annot_id => a.id,
            :num => 1,
            :cat_idx => i,
            :cell_set_id => (h_cell_sets[i]) ? h_cell_sets[i].id : nil,
            :cell_ontology_term_ids => cot_ids,
            :ontology_term_type_id => ott_id_by_cot_id[cot.id],
            :cat => k,
            :user_id => a.user_id,
            :project_id => a.project_id
          }

          annot_cat_key = [a.id, i]
          if cla_by_annot_cat.key?(annot_cat_key)
            cla = cla_by_annot_cat[annot_cat_key]
          else
            cla = existing_clas_for_annot[i]
          end
          if !cla
            cla = Cla.new(h_cla)
            cla.save
          elsif cla.cla_source_id == ASAP_AUTO_CLA_SOURCE_ID
            cla.assign_attributes(h_cla)
            cla.save if cla.changed?
          end
          cla_by_annot_cat[annot_cat_key] = cla
          existing_clas_for_annot[i] ||= cla
          sel_clas.push cla.id
        else
          # No perfect ontology match: do not create/update ASAP auto Clas (leave orphans for manual review).
          sel_clas.push ""
        end
      end

      h_cla_sum = {
        :nber_clas => (0 .. list_cats.size-1).to_a.map{|i| (sel_clas[i] == '') ? 0 : 1},
        :selected_cla_ids => sel_clas
      }

      a.update({:cat_info_json => h_cla_sum.to_json})
    end
    
    # Map output.json log fields (is_log_transformed, log_type, log_base) to data_transformations.id.
    # Returns nil when log status is unknown or not provided.
    def data_transformation_id_from_log_attrs(attrs)
      return nil unless attrs.is_a?(Hash)
      return nil unless attrs.key?('is_log_transformed')

      transformed = attrs['is_log_transformed']
      if transformed == false || transformed == 0 || transformed == '0' || transformed.to_s.downcase == 'false'
        return 1
      end
      unless transformed == true || transformed == 1 || transformed == '1' || transformed.to_s.downcase == 'true'
        return nil
      end

      log_type = attrs['log_type'].to_s.downcase
      return nil if log_type.include?('pearson') || log_type.include?('residual')

      base = attrs['log_base']
      return 2 if base.to_f == 10.0 || log_type.include?('log10')
      return 3 if base.to_f == 2.0 || log_type.include?('log2')

      4
    end

    def output_log_transform_block(h_results, step_name)
      return nil unless h_results.is_a?(Hash) && step_name.present?

      block = h_results[step_name]
      return block if block.is_a?(Hash) && block.key?('is_log_transformed')

      nil
    end

    def input_matrix_data_transformation_id_for_run(run, h_attrs = nil, cache = nil)
      cache ||= {}
      return cache[:input_matrix_data_transformation_id] if cache.key?(:input_matrix_data_transformation_id)

      h_attrs ||= Basic.safe_parse_json(run.attrs_json, {})
      im = h_attrs['input_matrix']
      im = im.first if im.is_a?(Array) && im.any?
      im = im if im.is_a?(Hash)

      annot = nil
      if im.is_a?(Hash)
        if im['annot_id'].present?
          annot = Annot.find_by(id: im['annot_id'])
        elsif im['output_dataset'].present?
          scope = Annot.where(project_id: run.project_id, name: im['output_dataset'])
          scope = scope.where(filepath: im['output_filename']) if im['output_filename'].present?
          scope = scope.where(run_id: im['run_id']) if im['run_id'].present?
          annot = scope.order(id: :desc).first
        end
      end

      cache[:input_matrix_data_transformation_id] = annot&.data_transformation_id
    end

    # v8 tools often put matrix shape in output.json metadata[] instead of top-level nber_rows/nber_cols.
    def matrix_dims_from_results(h_results, dataset_name, h_metadata_by_name = {})
      meta = h_metadata_by_name[dataset_name]
      nber_rows = h_results['nber_rows'].presence || meta&.[]('nber_rows')
      nber_cols = h_results['nber_cols'].presence || meta&.[]('nber_cols')
      dataset_size = meta&.[]('dataset_size')
      dataset_size ||= (nber_rows.present? && nber_cols.present?) ? 4 * nber_rows.to_i * nber_cols.to_i : nil
      is_count = h_results['is_count_table'].to_i == 1 || meta&.[]('is_count_table').to_i == 1
      { 'nber_rows' => nber_rows, 'nber_cols' => nber_cols, 'dataset_size' => dataset_size, 'is_count' => is_count }
    end

    STALE_STEP_OUTPUT_FILES = %w[
      output.json output.log exec.out exec.err output.plot.json exec_run_details.log
    ].freeze

    def run_output_dir(run)
      project = run.project
      step = run.step
      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
      step_dir = project_dir + step.name
      (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
    end

    def parse_exec_run_details(path)
      file_path = path.to_s
      return {} unless file_path.present? && File.exist?(file_path)

      h_time_info = {}
      File.readlines(file_path).each do |line|
        entries = line.split(',')
        next unless entries.size > 1

        entries.each do |entry|
          next unless (m = entry.match(/^([A-Za-z])=([\d\:.]+)$/))

          h_time_info[m[1]] = m[2]
        end
      end

      max_ram_mb = h_time_info['M'].present? ? (h_time_info['M'].to_f / 1024.0).round(2) : nil
      process_duration_seconds = parse_time_elapsed_seconds(h_time_info['E'])

      {
        time_info: h_time_info,
        max_ram_mb: max_ram_mb,
        process_duration_seconds: process_duration_seconds
      }
    end

    def parse_time_elapsed_seconds(elapsed)
      return nil if elapsed.blank?

      total = 0.0
      parts = elapsed.split(':')
      if parts.size == 1
        elapsed.scan(/([\d.]+)s/) { |m| total += m[0].to_f }
        elapsed.scan(/([\d]+)m/) { |m| total += m[0].to_f * 60 }
        elapsed.scan(/([\d]+)h/) { |m| total += m[0].to_f * 3600 }
        elapsed.scan(/([\d]+)d/) { |m| total += m[0].to_f * 3600 * 24 }
        return total.round(2)
      end

      total += parts.shift.to_f * 3600 if parts.size == 3
      return nil unless parts.size == 2

      total += parts[0].to_f * 60
      total += parts[1].to_f
      total.round(2)
    end

    # Remove result files from a step output directory when a run is (re)started.
    # Keeps subdirectories such as input/ intact. Steps with multiple_runs=false share
    # the step directory, so this must run at submission time (see RunExecutionJob).
    def clear_step_run_output_files!(run, logger: nil)
      output_dir = run_output_dir(run)
      return unless output_dir

      FileUtils.mkdir_p(output_dir) unless File.directory?(output_dir.to_s)

      removed = []
      STALE_STEP_OUTPUT_FILES.each do |fname|
        fpath = output_dir + fname
        next unless File.file?(fpath.to_s)

        File.delete(fpath.to_s)
        removed << fname
      end

      slurm_script = output_dir + "slurm_#{run.id}.sh"
      if File.file?(slurm_script.to_s)
        File.delete(slurm_script.to_s)
        removed << slurm_script.basename.to_s
      end

      if removed.any?
        (logger || Rails.logger).info(
          "[Basic.clear_step_run_output_files] Run##{run.id} cleared #{removed.join(', ')} in #{output_dir}"
        )
      end
    end

    # When a shared step/output.json is read before the current job finishes, annots can get
    # dimensions from a previous run. Reconcile from the on-disk output.json when they differ.
    # Uses each metadata entry's own nber_rows/nber_cols — never top-level matrix shape
    # (matrix_dims_from_results prefers those and would corrupt 1D gene/cell vectors).
    #
    # dry_run: when true, logs planned updates but does not write.
    # Returns true if any annot would be / was updated.
    def sync_run_annots_from_output_json!(logger, run, dry_run: false)
      plan = plan_sync_run_annots_from_output_json(run)
      return false if plan.nil? || plan[:changes].empty?

      prefix = dry_run ? '[DRY-RUN] ' : ''
      plan[:changes].each do |change|
        logger.info(
          "#{prefix}[Basic.sync_run_annots_from_output_json] Run##{run.id} #{change[:name]}: " \
          "#{change[:from_rows]}x#{change[:from_cols]} -> #{change[:to_rows]}x#{change[:to_cols]}"
        )
        next if dry_run

        change[:annot].update!(
          nber_rows: change[:to_rows],
          nber_cols: change[:to_cols]
        )
      end
      true
    end

    # Returns nil if no usable output.json; otherwise { changes: [Hash, ...] }.
    # Each change: :annot, :name, :from_rows, :from_cols, :to_rows, :to_cols
    def plan_sync_run_annots_from_output_json(run)
      output_json_path = run_output_dir(run) + 'output.json'
      return nil unless File.exist?(output_json_path.to_s)

      h_results = safe_parse_json(File.read(output_json_path), {})
      return nil unless h_results.is_a?(Hash)

      metadata = h_results['metadata']
      metadata = metadata.is_a?(Array) ? metadata : (metadata ? [metadata] : [])
      return nil if metadata.empty?

      h_metadata_by_name = {}
      metadata.each do |m|
        next unless m.is_a?(Hash) && m['name'].present?
        h_metadata_by_name[normalize_dataset_path(m['name'])] = m
      end

      changes = []
      Annot.where(run_id: run.id).find_each do |annot|
        meta = h_metadata_by_name[normalize_dataset_path(annot.name)]
        next unless meta

        nr = meta['nber_rows']
        nc = meta['nber_cols']
        next if nr.blank? || nc.blank?

        next if annot.nber_rows.to_i == nr.to_i && annot.nber_cols.to_i == nc.to_i

        changes << {
          annot: annot,
          name: annot.name,
          from_rows: annot.nber_rows.to_i,
          from_cols: annot.nber_cols.to_i,
          to_rows: nr.to_i,
          to_cols: nc.to_i
        }
      end
      { changes: changes }
    end

    # DB-only: attr annots whose nber_rows x nber_cols equal the loom /matrix shape
    # (vector metadata wrongly stamped with matrix dims). No output.json required.
    # Target shape from dim (or path): CELL => 1 x n_cols, GENE => n_rows x 1, GLOBAL => 1 x 1.
    # Returns { changes: [...] } (possibly empty).
    def plan_matrix_shaped_vector_annot_repairs(project_id: nil, run_id: nil)
      binds = []
      sql = <<~SQL
        SELECT a.id AS annot_id,
               a.run_id,
               a.project_id,
               a.name,
               a.dim,
               a.nber_rows AS from_rows,
               a.nber_cols AS from_cols,
               m.nber_rows AS matrix_rows,
               m.nber_cols AS matrix_cols
        FROM annots a
        INNER JOIN annots m
          ON m.project_id = a.project_id
         AND m.filepath = a.filepath
         AND m.name = '/matrix'
        WHERE a.run_id IS NOT NULL
          AND a.dim IS DISTINCT FROM 3
          AND a.nber_rows > 1
          AND a.nber_cols > 1
          AND a.nber_rows = m.nber_rows
          AND a.nber_cols = m.nber_cols
          AND (
            a.name LIKE '/col_attrs/%'
            OR a.name LIKE '/row_attrs/%'
            OR a.name LIKE '/attrs/%'
          )
      SQL
      if project_id
        sql += ' AND a.project_id = ?'
        binds << project_id
      end
      if run_id
        sql += ' AND a.run_id = ?'
        binds << run_id
      end
      sql += ' ORDER BY a.project_id, a.run_id, a.id'

      rows = if binds.any?
               ActiveRecord::Base.connection.select_all(
                 ActiveRecord::Base.sanitize_sql_array([sql, *binds])
               )
             else
               ActiveRecord::Base.connection.select_all(sql)
             end

      annots_by_id = Annot.where(id: rows.map { |r| r['annot_id'] }).index_by(&:id)
      changes = []
      rows.each do |row|
        annot = annots_by_id[row['annot_id'].to_i]
        next unless annot

        to_rows, to_cols = inferred_vector_dims_for_annot(
          annot,
          matrix_rows: row['matrix_rows'].to_i,
          matrix_cols: row['matrix_cols'].to_i
        )
        next if to_rows.nil? || to_cols.nil?
        next if annot.nber_rows.to_i == to_rows && annot.nber_cols.to_i == to_cols

        changes << {
          annot: annot,
          name: annot.name,
          from_rows: annot.nber_rows.to_i,
          from_cols: annot.nber_cols.to_i,
          to_rows: to_rows,
          to_cols: to_cols,
          source: 'matrix_shape+dim'
        }
      end
      { changes: changes }
    end

    # CELL/dim1 => 1 x n_cells; GENE/dim2 => n_genes x 1; GLOBAL/dim4 => 1 x 1
    def inferred_vector_dims_for_annot(annot, matrix_rows:, matrix_cols:)
      axis = case annot.dim.to_i
             when 1 then :cell
             when 2 then :gene
             when 4 then :global
             else
               name = annot.name.to_s
               if name.start_with?('/col_attrs/') then :cell
               elsif name.start_with?('/row_attrs/') then :gene
               elsif name.start_with?('/attrs/') then :global
               end
             end
      case axis
      when :cell then [1, matrix_cols]
      when :gene then [matrix_rows, 1]
      when :global then [1, 1]
      else [nil, nil]
      end
    end

    def normalize_dataset_path(path)
      s = path.to_s.strip
      return '' if s.empty?

      s.start_with?('/') ? s : "/#{s}"
    end

    # Dataset paths declared in step.output_json expected_outputs (with #{var} substitution).
    def resolved_expected_output_datasets(step, h_var = {})
      return [] unless step&.output_json.present?

      h_output = safe_parse_json(step.output_json, {})
      h_expected = h_output['expected_outputs']
      return [] unless h_expected.is_a?(Hash)

      datasets = []
      h_expected.each_value do |cfg|
        next unless cfg.is_a?(Hash) && cfg['dataset'].present?

        dataset = cfg['dataset'].to_s
        if h_var.present? && dataset.match(/#\{/)
          dataset = dataset.gsub(/(\#\{[\w_]+?\})/) { |var| h_var[var[2..-2]].to_s }
        end
        datasets << normalize_dataset_path(dataset)
      end
      datasets.uniq
    end

    # Legacy fix_annots.rake: only on parsing, annots whose dataset is not a declared
    # expected output (typically /matrix) were present in the source loom and are imported.
    # Do not apply to de, normalization, etc. — those runs produce many annots outside
    # expected_outputs that are still ASAP pipeline outputs.
    def apply_imported_flag_for_unexpected_outputs!(run, meta, cache = nil)
      return if meta['imported'] == true
      return unless run.step&.name == 'parsing'

      cache ||= {}
      unless cache.key?(:resolved_expected_datasets)
        cache[:resolved_expected_datasets] = resolved_expected_output_datasets(run.step, {})
      end
      expected = cache[:resolved_expected_datasets]
      return if expected.empty?

      name = normalize_dataset_path(meta['name'])
      return if name.empty?
      return if expected.include?(name)

      meta['imported'] = true
    end

    # Same rules as load_annot when imported=true: infer data_class_names from path and data type.
    def infer_imported_data_class_names(name, type_name = nil)
      data_class_names = path_base_data_class_names(name)
      value_class = value_mdata_class_for_type(type_name)
      data_class_names << value_class if value_class
      data_class_names.uniq
    end

    def path_base_data_class_names(name)
      data_class_names = []
      if name.to_s.match?(%r{^/layers/})
        data_class_names |= %w[dataset matrix num_matrix]
      elsif name.to_s.match?(%r{^/col_attrs/})
        data_class_names |= %w[dataset mdata col_mdata]
      elsif name.to_s.match?(%r{^/row_attrs/})
        data_class_names |= %w[dataset mdata row_mdata]
      elsif name.to_s.match?(%r{^/attrs/})
        data_class_names |= %w[global_mdata]
      elsif name == '/matrix'
        data_class_names |= %w[dataset matrix int_matrix]
      end
      data_class_names
    end

    def value_mdata_class_for_type(type_name)
      case type_name.to_s.upcase
      when 'NUMERIC' then 'numeric_mdata'
      when 'DISCRETE', 'CATEGORICAL' then 'discrete_mdata'
      when 'STRING' then 'string_mdata'
      when 'NOT_HANDLED' then 'not_handled_mdata'
      end
    end

    # Recompute storage-related data classes when the user changes data type.
    # For expression matrices, int_matrix vs num_matrix is preserved unless unknown.
    def data_class_names_for_data_type(name, type_name, keep_matrix_storage: nil)
      path = name.to_s
      names = path_base_data_class_names(path)
      value_mdata_classes = %w[numeric_mdata discrete_mdata string_mdata not_handled_mdata integer_mdata]

      if path == '/matrix' || path.match?(%r{^/layers/})
        matrix_storage =
          if keep_matrix_storage.to_s.in?(%w[int_matrix num_matrix])
            keep_matrix_storage.to_s
          elsif path == '/matrix'
            'int_matrix'
          else
            'num_matrix'
          end
        names.reject! { |n| n == 'int_matrix' || n == 'num_matrix' }
        names << matrix_storage
      else
        value_class = value_mdata_class_for_type(type_name)
        names.reject! { |n| value_mdata_classes.include?(n) }
        names << value_class if value_class
      end

      names.compact.uniq
    end

    def backfill_imported_annot_data_classes!(annot)
      return false unless annot.imported?
      return false if annot.data_class_ids.present?

      type_name = annot.data_type&.name
      names = infer_imported_data_class_names(annot.name, type_name)
      return false if names.empty?

      ids = names.filter_map { |n| DataClass.find_by(name: n)&.id }.uniq
      return false if ids.empty?

      annot.update!(data_class_ids: ids.join(','))
      true
    end

    def load_annot run, meta, relative_filepath, h_data_types, h_data_classes, logger, cache = nil
      cache ||= {}
      project_by_id = cache[:project_by_id] ||= {}
      annot_by_key = cache[:annot_by_key] ||= {}
      ori_annot_by_name = cache[:ori_annot_by_name] ||= {}
      de_step_ids = cache[:de_step_ids] ||= Step.where(:name => 'de').pluck(:id)
      
      #list_metadata.each do |meta|
      if project_by_id.key?(run.project_id)
        project = project_by_id[run.project_id]
      else
        project = Project.where(:id => run.project_id).first #run.project
        project_by_id[run.project_id] = project
      end

      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
    
      
      #      if annot = Annot.where(:project_id => run.project_id, :name => meta['name'], :run_id => run.id).first
      #        annot.destroy          
      #      end
      
      #      annot_path = meta['name']
      #      t =  meta['name'].split("/")
      #      annot_name = meta['name'].gsub(/(\/.{3}_attrs\/)/, '')

      #      relative_filepath = relative_path(project, filepath)

      # create or update fo
      fo = create_upd_fo(run.project_id, relative_filepath, cache)
      annot_key = [run.project_id, meta['name'], relative_filepath, (fo ? fo.run_id : nil)]
      if annot_by_key.key?(annot_key)
        annot = annot_by_key[annot_key]
      else
        annot = Annot.where(:name => meta['name'], :filepath => relative_filepath, :store_run_id => (fo) ? fo.run_id : nil, :project_id => run.project_id).first
        annot_by_key[annot_key] = annot
      end
      
      # complete annotation details if data type is not defined      
      #      if !meta['type'] or !meta['dataset_size']
      ## get same annotation from parsing
      ori_annot_key = [project.id, meta['name']]
      if ori_annot_by_name.key?(ori_annot_key)
        ori_annot = ori_annot_by_name[ori_annot_key]
      else
        ori_annot = Annot.where(:project_id => project.id, :name => meta['name']).order("id asc").first
        ori_annot_by_name[ori_annot_key] = ori_annot
      end
      if ori_annot and annot != ori_annot ## second part of expression: in case of re-importing a metadata or creating again the same metadata, do not get the metadata attributes from the previous metadata version (it might be outdated, for example in the case of imported metadata => the type can me changed by the user)
        meta["type"] = (dt = ori_annot.data_type) ? dt.name : nil
        if ori_annot.data_class_ids and ori_annot.data_class_ids != ''
          meta["data_class_names"] = ori_annot.data_class_ids.split(",").map{|e| 
            dc = h_data_classes[e.to_i]
            dc ? dc.name : nil
          }.compact
        end
        meta["imported"] = ori_annot.imported
      end
      apply_imported_flag_for_unexpected_outputs!(run, meta, cache)
      if meta['forced_type_id'] && (fdt = h_data_types[meta['forced_type_id']])
        meta['type'] = fdt.name
      end

      loom_path = project_dir + relative_filepath
      if meta['data_class_names'] and meta['data_class_names'].include?("discrete_mdata")
        meta["type"]= 'DISCRETE'
      end
      if meta['forced_type_id']
        type_for_extract = h_data_types[meta['forced_type_id']]&.name
        no_values = meta['type'] != 'DISCRETE'
        meta_compl = H5DataService.extract_metadata_compl(
          loom_path.to_s,
          meta['name'],
          type_name: type_for_extract,
          no_values: no_values
        )
        logger&.info("[Basic.load_annot] forced_type_id extract name=#{meta['name']} type=#{type_for_extract} keys=#{meta_compl.keys.inspect}")
      else
        meta_compl = {}
      end

      ## complement for h5ad existing_metadata or if we want to change type (call from annot update)
      ['type', 'on', 'nber_rows', 'nber_cols', 'dataset_size'].each do |k|
        meta[k] ||= meta_compl[k] 
      end

      ## override certain parameters
      list_p = ['nber_cols', 'nber_rows', 'dataset_size']
      list_p.push("categories") if meta["type"] == 'DISCRETE'
      list_p.each do |k|
        meta[k] = meta_compl[k] if meta_compl[k]
      end

      data_class_names = meta['data_class_names'] || []
      explicit_data_classes = meta.key?('data_class_names') && meta['data_class_names'].is_a?(Array)
      
      ### if imported data, try to guess types
      #if data_class_names.size == 0 #meta['imported'] == true
      if !explicit_data_classes && (meta['imported'] == true or meta['forced_type_id']) #or data_class_names.size == 0
        inferred = infer_imported_data_class_names(meta['name'], meta['type'])
        data_class_names |= inferred if inferred.any?
        if meta['on'] == 'EXPRESSION_MATRIX' # meta['nber_cols'] > 1 and meta['nber_rows'] > 1 and meta["type"] == 'NUMERIC'
          data_class_names |= ['matrix', 'num_matrix']
        end
      end
      
      data_classes = []
      data_class_names.each do |data_class_name|
        if !data_class = h_data_classes[data_class_name] and !data_class = DataClass.where(:name => data_class_name).first
          data_class = DataClass.new(:name => data_class_name)
          data_class.save
          h_data_classes[data_class_name]= data_class
        end
        data_classes.push h_data_classes[data_class_name]
      end

      output_attr = nil
      if meta['output_attr_name']
        output_attr = OutputAttr.where(:name => meta['output_attr_name']).first
        if !output_attr
          output_attr = OutputAttr.new(:name => meta['output_attr_name'])
          output_attr.save
        end
      end
      
      # meta.delete('data_class_names') if meta['data_class_names']
      
      h_meta_types = {
        'EXPRESSION_MATRIX' => 3,
        'GLOBAL' => 4,
        'CELL' => 1,
        'GENE' => 2
      }

      # Legacy DE tools omitted headers; de.v8.py now sends "headers" from output.json.
      meta['headers'] ||= meta['header'] if meta['header'].is_a?(Array)
      if !meta['headers'] && de_step_ids.include?(run.step_id)
        meta['headers'] = ["logFC", "P-value", "FDR", "Avg group1", "Avg group2"]
      end

      ori_annot2 = nil

      if meta['name'] != '/matrix'
        ori_annot2 = ori_annot
      end
      
      allow = true

      ## do not propagate de results     
      allow = false if fo.run_id == run.id and meta['on'] == 'GENE' and meta['name'].match(/_de_\d+/) and meta['imported'] == false


      if allow

        list_cats = nil
        if meta['categories']
          nber_int = meta['categories'].keys.select{|k| k.match(/^-?\d+$/)}.size
          nber_float = meta['categories'].keys.select{|k| k.match(/^-?\d*\.?\d+?$/)}.size
          if nber_int == meta['categories'].keys.size
            list_cats = meta['categories'].keys.map{|e| [e.to_i, e]}.sort{|a,b| a[0] <=> b[0]}.map{|e| e[1]}
          elsif  nber_float == meta['categories'].keys.size
            list_cats = meta['categories'].keys.map{|e| [e.to_f,e]}.sort{|a,b| a[0] <=> b[0]}.map{|e| e[1]}
          else
            list_cats = meta['categories'].keys.sort
          end
        end
        h_annot = {
          :project_id => run.project_id,
          :step_id => run.step_id,
          :run_id => run.id,
          :filepath => relative_filepath,
          :store_run_id => (fo) ? fo.run_id : nil,
          :ori_run_id => (ori_annot2) ? ori_annot2.run_id : run.id,
          :ori_step_id => (ori_annot2) ? ori_annot2.step_id : run.step_id,
          :headers_json => Annot.headers_json_from_meta(meta), 
          # :fo_id => (fo) ? fo.id : nil,
          :name => meta['name'],
          :categories_json => (meta['categories']) ? meta['categories'].to_json : nil,
          :list_cat_json => (list_cats) ? list_cats.to_json : nil, #(meta['categories']) ? meta['categories'].keys.sort.to_json : nil,
          :dim => (h_meta_types[meta['on']]) ? h_meta_types[meta['on']] : nil, #(meta['on'] == 'EXPRESSION_MATRIX') ? 3 : ((meta['on'] == 'CELL') ? 1 : 2),
          :data_type_id => (dt = h_data_types[meta['type']]) ? dt.id : nil,
          :nber_cats => (meta['categories']) ? meta['categories'].size : nil,
          :nber_rows => meta['nber_rows'],
          :nber_cols => meta['nber_cols'],
          :data_class_ids => data_classes.flatten.uniq.map{|e| e.id}.sort.join(","),
          :mem_size => meta['dataset_size'], # (meta['nber_cols'] and  meta['nber_rows']) ? 4 * meta['nber_cols'] * meta['nber_rows'] : nil,
          :label => nil,
          :imported => (meta['imported'] == true) ? true : false,
          :output_attr_id => (output_attr) ? output_attr.id : nil,
          :user_id => run.user_id
        }

        if meta['on'] == 'EXPRESSION_MATRIX' || meta['name'].to_s.start_with?('/layers/')
          dt_id = if meta.key?('is_log_transformed')
                    data_transformation_id_from_log_attrs(meta)
                  elsif cache && cache[:data_transformation_from_output]
                    cache[:data_transformation_id]
                  else
                    cache[:data_transformation_id] if cache
                  end
          h_annot[:data_transformation_id] = dt_id unless dt_id.nil?
        end
        
#        annot = Annot.where(:name => meta['name'], :filepath => relative_filepath, :store_run_id => (fo) ? fo.run_id : nil, :project_id => run.project_id).first

        if h_annot[:data_class_ids].blank? && annot&.data_class_ids.present?
          h_annot[:data_class_ids] = annot.data_class_ids
        end

        if !annot
          annot = Annot.new(h_annot)
          annot.save!
          annot_by_key[annot_key] = annot
          ori_annot_by_name[ori_annot_key] ||= annot
        elsif !(h_annot[:data_class_ids] == '' and annot.data_class_ids != '')
          annot.update(h_annot)
          annot_by_key[annot_key] = annot
        end

        ## save list of stable_ids in file
        stable_ids_file = project_dir + (annot.filepath + ".stable_ids")
        if !File.exist? stable_ids_file #annot.store_run_id == annot.run_id and annot.dim == 3
          cmd = "java -jar #{ENV.fetch('LOCAL_ASAP_RUN_DIR')}/ASAP.jar -T ExtractMetadata -loom #{project_dir + annot.filepath} -meta /col_attrs/_StableID"
       #   res = Basic.safe_parse_json(`#{cmd}`, {})
       #   stable_ids = res['values']
          File.open(stable_ids_file, "w") do |fout|
            fout.write(`#{cmd}`)
          end
        end
        
        ## add clas
        if annot.data_type_id == 3 and annot.dim == 1 
          h_cell_sets = add_cell_sets(project, project_dir, annot, meta_compl, list_cats, cache)
          add_clas(project, annot, h_cell_sets, cache)
        end
        
        ## compute_marker genes
        if project.user_id == 1 and project.sandbox == false
          
          #        cell_metadata = project.annots.select{|a| a.data_type_id ==3 and a.dim == 1}
          #        cell_metadata.each do |meta|
          if annot.data_type_id == 3 and annot.dim == 1
#            h_markers = Basic.find_markers(logger, project, annot, run.user_id)
#            h_marker_enrichment = Basic.find_marker_enrichment(logger, project, annot, h_markers[:run], run.user_id)
          end
        end
      end

      return annot
      #end
      #list_res = JSON.parse(res) 
    end

    def get_project_step_details project, step_id
      #logger.debug("Get project_step details for " + project.key + " and step " + step_id)
      h_project_step = {}
      h_nber_runs = {}
      step = Step.find_by(id: step_id)
      runs = Run.where(:project_id => project.id, :step_id => step_id).all
      runs.each do |run|
        h_nber_runs[run.status_id] ||= 0
        h_nber_runs[run.status_id] += 1
      end
      # Single-run steps cannot be both waiting and running at the same time.
      if step && step.multiple_runs != true && h_nber_runs[2].to_i > 0
        h_nber_runs[1] = 0
      end
      if runs.size == 0
         h_project_step[:status_id] = nil
      else
        [1, 3, 4, 2].each do |status_id|
          h_project_step[:status_id] = status_id if h_nber_runs[status_id] and h_nber_runs[status_id] > 0
        end
      end
      
      h_project_step[:nber_runs_json] = h_nber_runs.to_json
      
      return h_project_step

    end

    def upd_project_size project
      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
      if File.exist? project_dir
        project.update(:disk_size => `du -s #{project_dir}`.split(/\s+/).first.to_i * 1000)
      else
        puts "Project directory does not exist. Current size in DB: #{project.disk_size}" 
      end
    end

    def upd_project_step project, step_id
      h_project_step = Basic.get_project_step_details(project, step_id)
      all_project_steps = ProjectStep.where(:project_id => project.id).order(:id).all
      step_rows = all_project_steps.select { |e| e.step_id == step_id }
      if step_rows.size > 1
        duplicate_ids = step_rows[0..-2].map(&:id)
        ProjectStep.where(id: duplicate_ids).delete_all if duplicate_ids.any?
        all_project_steps = ProjectStep.where(:project_id => project.id).order(:id).all
        step_rows = all_project_steps.select { |e| e.step_id == step_id }
      end
      project_step = step_rows.last
      if project_step
        project_step.update(h_project_step)
      end
      # puts "PROJECT_STEP: " + project_step.to_json
      ### update project stats
      h_steps = {}
      Step.all.map{|s| h_steps[s.id] = s}
      h_nber_runs = {}

      # Defensive deduplication by step_id to avoid over-counting when duplicate ProjectStep rows exist.
      latest_project_steps = all_project_steps.group_by(&:step_id).transform_values { |rows| rows.last }.values
      latest_project_steps.select{|ps| h_steps[ps.step_id].hidden == false}.each do |ps|
        h_tmp = JSON.parse(ps.nber_runs_json)
        h_tmp.keys.map{|k| h_nber_runs[k]||=0; h_nber_runs[k] += h_tmp[k]}
      end
      # puts h_nber_runs.to_json
      h_upd = {:nber_runs_json => h_nber_runs.to_json}
      if h_steps[step_id].hidden == false ## do not change modified_at when executing hidden step runs
        h_upd[:modified_at] = Time.now 
      end
      project.update(h_upd)
    end

    def save_run run
      run.save
     # h_active_run = run.as_json
     # h_active_run[:run_id]= run.id
     # h_active_run.delete(:id)
     # active_run = ActiveRun.new(h_active_run)
     # active_run.save!
    end

    def upd_run project, run, h_upd, upd_project_step
    #  puts "PROBLEM_HERE"
      success = run.update(h_upd)
      unless success
        Rails.logger.error("[Basic.upd_run] Failed to update Run##{run.id}: #{run.errors.full_messages.join(', ')}")
      end
      
      # Reload run to ensure we have the latest status from database
      run.reload
      
      flag_change_status = (h_upd[:status_id] and h_upd[:status_id] != run.status_id) ? true : false
    
      ### active run thingy....
      # max_try = 5 ###the active run might be not yet created
      # try = 0
      # while ( try < max_try and !run.active_run ) do 
      #   try+=1
      # end
      # if (active_run = run.active_run)
      #   #        if h_upd[:status_id] == 4
      #   #          active_run.delete          
      #   #        else
      #   active_run.update(h_upd)
      #   sleep(0.3)
      # end
      

      ### update project_step
      #if flag_change_status == true
      if  upd_project_step
        upd_project_step project, run.step_id
      end
      #end

    end

    def set_run logger, h_p

      h_res = {}

#      puts "Elapsed time 9a:" + (Time.now-h_p[:el_time]).to_s

      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + h_p[:project].user_id.to_s + h_p[:project].key
      run = h_p[:run] #list_of_runs[run_i][0]
      p = h_p[:p] #list_of_runs[run_i][1]
 #     h_step_attrs = JSON.parse(run.step.attrs_json)
      logger.debug("SET_RUN")
      docker_image = h_p[:h_cmd_params]['docker_image']
     # step = run.step
      step_dir = project_dir + h_p[:step].name
      Dir.mkdir step_dir if !File.exist? step_dir
      output_dir = (h_p[:step].multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
      Dir.mkdir output_dir if !File.exist? output_dir
      
      h_attrs = JSON.parse(h_p[:run].attrs_json)

#      version = h_p[:project].version
#      asap_docker_image = get_asap_docker(version)

#      Step.where(:docker_image_id => asap_docker_image.id).all.each do |s|
#        h_steps[s.id] = s
#      end
      
      std_method = h_p[:std_method]
      step = h_p[:step]
      h_var = {
        'user_id' => h_p[:run].user_id,
        'project_dir' => project_dir,        
        'output_dir' => output_dir, #project_dir + h_p[:step].name + run.id.to_s,
        'std_method_name' => std_method.name,
        'std_method_label' => std_method.label.presence || step.label,
        'std_method_short_label' => std_method.short_label.presence || std_method.name.presence || step.name,
        'step_tag' => step.tag,
        'step_name' => step.name,
        'run_num' => run.num,
        'asap_data_docker_db_conn' => Basic.asap_data_db_url(h_p[:h_env]),
        'asap_data_direct_db_conn' => 'postgres:5433/' + Basic.asap_data_db_name_from_env!(h_p[:h_env]), #h_p[:project].version_id.to_s,
        'asap_docker_db_conn' => 'postgres:5434/' + ENV["POSTGRES_DB"]
      }

      #      puts "Elapsed time 9b:" + (Time.now-h_p[:el_time]).to_s

      ###optional variables stored in 
      #['output_matrix_dataset'].each do |e|
      #  
      #end
      
      h_std_method_attrs = JSON.parse(h_p[:std_method].attrs_json)
      
      run_parents = []
      h_parent_runs = {}
      
      new_h_attrs = JSON.parse(run.attrs_json)
#      if gp = new_h_attrs['group_pairs']
#        new_h_attrs['group_ref'] = gp[0]
#        new_h_attrs['group_comp'] = gp[1]
#      end
      
  #    puts "Elapsed time 9c:" + (Time.now-h_p[:el_time]).to_s
      logger.debug("P_DEBUG:" + p.to_json)
      puts p.to_json
      p.each_key do |k|
        logger.debug("ATTR:" + k)
#        ### write in files some parameters that take too much space and replace in db by a SHA2                                                                                                    
#        if filename = @h_attrs[k]['write_in_file']
#          filepath = output_dir + filename
#          File.open(filepath, 'w') do |f|
#            f.write(params[:attrs][k])
#          end
#          sha2 = Digest::SHA2.hexdigest params[:attrs][k]
#          new_h_attrs = JSON.parse(run.attrs_json)
#          new_h_attrs[k] = sha2
#        end
        
        ### apply write_in_file               
        #        @h_attrs.each_key do |k|
        #     if filename = h_p[:h_attrs][k.to_s]['write_in_file']
        #       filepath = h_var['output_dir'] + filename
        #       File.open(filepath, 'w') do |f|
        #         f.write(h_p[:h_attrs][k.to_s])
        #       end
        #     end
        
        #logger.debug("bly: #{k.to_s} #{@h_attrs.to_json} #{@h_attrs[k.to_s].to_json}")                                                                                                           
        logger.debug("ATTRS:" + h_p[:h_attrs].to_json)
        if h_p[:h_attrs][k.to_s] and h_p[:h_attrs][k.to_s]['valid_types']
          logger.debug("ATTR2:" + k)
          ### handle annotations (that are not considered as datasets - but can still be used as input)

          ### handle datasets
          
          if h_p[:h_attrs][k.to_s]['valid_types'].flatten.include?('dataset')
            logger.debug("ATTR3:" + k)
            list_datasets = []
            if h_p[:h_attrs][k.to_s]['req_data_structure'] == 'array' and !h_p[:h_attrs][k.to_s]['combinatorial_runs']
              # Optional multi-select (e.g. covariates): [] must stay [], not [[]]. Absent key / nil => no items.
              list_datasets = if p[k].is_a?(Array)
                p[k]
              elsif p[k].nil?
                []
              else
                logger.debug("ATTR4:" + p[k].to_json)
                [p[k]]
              end
            else
              list_datasets = [p[k]]
            end
            
            tmp_var = [] 

            ## get all annots
            h_annots = h_p[:h_annots]
#            h_annots = {}
#            Annot.where(:id => list_datasets.map{|dt| dt['annot_id']}.uniq.compact).all.map{|a| h_annots[a.id] = a}

            list_datasets.each do |dt|
              logger.debug("DATASET_ITEM: #{dt.to_json}")
              linked_annot = nil
              if dt['annot_id']
                linked_annot = h_annots[dt['annot_id']]
              #  linked_run = linked_annot.run
                dt['output_filename'] = linked_annot.filepath
                dt['output_dataset'] = linked_annot.name
                dt['output_attr_name'] = (oa = linked_annot.output_attr) ? oa.name : nil
              end

              if dt['output_dataset'].to_s.start_with?('/attrs/') && k.to_s != 'input_de'
                raise ::RuntimeError, "Dataset path under /attrs is not allowed for run inputs: #{dt['output_dataset']}"
              end
              
              linked_run = Run.where(:id => dt['run_id']).first
              h_parent_runs[linked_run.id] = linked_run

              # pca_seurat command_json arg 3 (norm_matrix_dataset): resolve from normalization
              # in the input matrix run's ancestors. Include linked_run itself — when the user
              # selects the normalization layer, lineage_run_ids often lists only parsing, not
              # the normalization run that produced the matrix.
              if k.to_s == 'input_matrix' && linked_run
                lineage_run_ids = linked_run.lineage_run_ids.to_s.split(',').map(&:strip).reject(&:blank?).map(&:to_i)
                lineage_run_ids << linked_run.id
                norm_dataset = Annot.joins(:step).where(
                  run_id: lineage_run_ids.uniq,
                  steps: { name: 'normalization' },
                  dim: 3
                ).order(id: :desc).first
                if norm_dataset
                  h_var['norm_matrix_dataset'] = norm_dataset.name
                elsif linked_run.step&.name == 'normalization' && dt['output_dataset'].present?
                  h_var['norm_matrix_dataset'] = dt['output_dataset']
                end

                filter_mdata = filter_mdata_from_lineage(
                  h_p[:project].id,
                  lineage_run_ids,
                  dt['output_filename']
                )
                if filter_mdata.present?
                  h_var['filter_mdata'] = filter_mdata
                  logger.debug("filter_mdata from gene_filtering lineage: #{filter_mdata}")
                end
              end

              h_linked_run_outputs = nil
              if !linked_run
                h_res[:error] = 'Linked run was not found!'
              else
                h_linked_run_outputs = JSON.parse(linked_run.output_json)
             #   if h_linked_run_outputs['annot']
                output_key = ['output_filename', 'output_dataset'].map{|e| dt[e]}.compact.join(":")
                if h_linked_run_outputs[dt['output_attr_name']]
                  h_linked_run_output = h_linked_run_outputs[dt['output_attr_name']][output_key]
                  if list_datasets.size == 1
                    if h_linked_run_output
                      h_linked_run_output.each_key do |k2|
                        h_var[k + "_" + k2] = h_linked_run_output[k2]
                      end
                      h_var[k + "_is_count_table"] = (h_linked_run_output["types"].flatten.include?("int_matrix")) ? 'true' : 'false'
                    end
                    h_var[k + "_filename"] = project_dir + dt['output_filename']                 
                    h_var[k + "_run_id"] = dt['run_id']
                    logger.debug ">>>>#{k}_run_id => #{dt['run_id']}"
                    
                    
                    #                 h_var[k + "_is_count_table"] = (h_linked_run_output["types"].flatten.include?("int_matrix")) ? 'true' : 'false' 
                  # else
                  end
                elsif linked_annot
                  
                  h_var[k + "_filename"] = project_dir + dt['output_filename']
                  h_var[k + "_dataset"] = dt['output_dataset']
                  h_var[k + "_run_id"] = dt['run_id']
                  h_var[k + "_is_count_table"] = (linked_annot["data_class_ids"].split(",").map{|e| h_p[:h_data_classes][e.to_i].name}.flatten.include?("int_matrix")) ? 'true' : 'false'
                else  
                  puts "Cannot find output with key #{(dt) ? dt['output_attr_name'] : 'NA'} #{linked_annot.to_json}!!!"
                end

                logger.debug("DATA_TMP:" + dt.to_json)
                logger.debug("LINKED_ANNOT:" + linked_annot.to_json)
                logger.debug("HVAR:" + h_var.to_json)
                if linked_annot and (['output_matrix', 'output_mdata'].include?(dt['output_attr_name']) or linked_annot.imported == true)
                #  ['nber_cols', 'nber_rows'].each do |v|
                  h_var['nber_cols'] = linked_annot.nber_cols if !h_var['nber_cols'] or h_var['nber_cols'] < linked_annot.nber_cols
                  h_var['nber_rows'] = linked_annot.nber_rows if !h_var['nber_rows'] or h_var['nber_rows'] < linked_annot.nber_rows
                  #  end
                end
                 logger.debug("HVAR2:" + h_var.to_json)
                ## if we consider linking datasets from other files
                #                  h_var[k].push((project_dir + dt['output_filename']) + ":" + dt['output_attr_name'])
                ## instead lets only consider the datasets from the current file and  restrict the available datasets to the file direct lineage + descendents
                dataset_field = (h_p[:h_attrs][k.to_s]['dataset_field']) ? h_p[:h_attrs][k.to_s]['dataset_field'] : "output_attr_name"
                cell = dt[dataset_field]
                if cell.nil? || cell.to_s.strip.empty?
                  # output_attr_name can be unset when output_attr has no name; loom path is still in output_dataset.
                  cell = dt['output_dataset']
                end
                tmp_var.push(cell)
                # end
                
                
                h_parent = {
                  :run_id => linked_run.id,
                  :lineage_run_ids => linked_run.lineage_run_ids,
                  :type => 'dataset',
                  :output_attr_name => dt['output_attr_name'],
                  #   :filename => dt['output_filename'], 
                  #   :dataset => dt['output_dataset'], #h_linked_run_output['dataset'],
                  :output_json_filename => (oj = h_linked_run_outputs['output_json']) ? oj.keys.first : nil,    
                  :input_attr_name => k.to_s
                }
                
                #                [:dataset].each do |e|
                #                  h_parent[e] =  h_linked_run_output[e.to_s]
                #                end
                
                run_parents.push(h_parent)
              end
            end
            attr_for_k = h_p[:h_attrs][k.to_s] || {}
            use_annot_id_in_h_var = command_json_boolean_truthy?(attr_for_k['set_h_var_to_annot_id'])

            if list_datasets.size > 1
              if use_annot_id_in_h_var
                ids = list_datasets.map { |dt| (dt['annot_id'] || dt[:annot_id]).to_i }.reject { |id| id <= 0 }
                if ids.size != list_datasets.size
                  raise StandardError, "set_h_var_to_annot_id is set for attr #{k.inspect} but each selection must include annot_id (#{list_datasets.size} items, #{ids.size} ids)"
                end
                h_var[k] = ids.join(',')
              else
                h_var[k] = tmp_var.join(",")
              end
            elsif use_annot_id_in_h_var
              dt0 = list_datasets[0]
              aid = (dt0 && (dt0['annot_id'] || dt0[:annot_id])).to_i
              if aid <= 0
                raise StandardError, "set_h_var_to_annot_id is set for attr #{k.inspect} but the selection has no annot_id"
              end
              h_var[k] = aid.to_s
            else
              h_var[k] = tmp_var[0]
            end

            # DE / Wilcoxon: always expose selected metadata annot id(s) for attrs "groups" / "groups2"
            # so command_json can use param_key groups_annot_id / groups2_annot_id without use_annot_id.
            case k.to_s
            when 'groups'
              gids = list_datasets.map { |dt| (dt['annot_id'] || dt[:annot_id]).to_i }.reject { |z| z <= 0 }
              h_var['groups_annot_id'] = gids.join(',') if gids.any?
            when 'groups2'
              gids = list_datasets.map { |dt| (dt['annot_id'] || dt[:annot_id]).to_i }.reject { |z| z <= 0 }
              h_var['groups2_annot_id'] = gids.join(',') if gids.any?
            end
          end
        else
          h_var[k] = p[k]
        end
      end

      if p['global_gene_set_item_id'].present? && p['global_gene_set_item_id'].to_s.strip != ''
        h_var['global_gene_set_db_conn'] = Basic.asap_data_db_url(h_p[:h_env])
      end

      if h_p[:step].name == 'ge'
        fdr_cutoff = p['fdr_cutoff'].presence || h_p[:h_attrs].dig('fdr_cutoff', 'default')
        fc_cutoff = p['fc_cutoff'].presence || h_p[:h_attrs].dig('fc_cutoff', 'default')
        write_ge_filtered_ids_json!(
          project_dir: project_dir,
          user_id: h_var['user_id'],
          input_de_run_id: h_var['input_de_run_id'],
          fdr_cutoff: fdr_cutoff,
          fc_cutoff: fc_cutoff,
          input_de: p['input_de'],
          h_annots: h_p[:h_annots] || {}
        )
      end

      if h_p[:step].name == 'heatmap'
        write_heatmap_config!(
          project: h_p[:project],
          output_dir: output_dir,
          h_var: h_var,
          p: p
        )
      end

#      puts "!H_VAR:" + h_var.to_json
#      logger.debug("!H_VAR:" + h_var.to_json)
      toto_path = project_dir + "tmp" + "toto.txt"
      FileUtils.mkdir_p((project_dir + "tmp").to_s)
      File.open(toto_path.to_s, "w") do |f|
        f.write(h_var.to_json + "\n")
        f.write(h_p.to_json + "\n")
      end
#       puts "Elapsed time 9d:" + (Time.now-h_p[:el_time]).to_s

      logger.debug("H_VAR: " + h_var.to_json)

      apply_de_annot_ids_from_command_json!(logger, h_p[:h_cmd_params], h_var, h_p[:project])
      apply_de_group_category_indices_from_command_json!(logger, h_p[:h_cmd_params], h_var, p, h_p[:h_annots], h_p[:project])

      db_json_cmd_meta = write_de_db_json!(logger, h_p[:h_cmd_params], h_var, p, h_p[:project], output_dir)

      ### update parents's children
      run_parents.each do |run_parent|
        parent_run = h_parent_runs[run_parent[:run_id]]
        children_run_ids = parent_run.children_run_ids.split(",")
        children_run_ids.push(run.id)
        #        parent_run.update_attribute(:children_run_ids, children_run_ids.join(","))
        h_upd = {:children_run_ids => children_run_ids.join(",")}
        upd_run h_p[:project], parent_run, h_upd, true
      end
      
 #     puts "Elapsed time 9e:" + (Time.now-h_p[:el_time]).to_s

      ## get all runs being in the lineages ## it is already done above one by one...
      #      h_all_runs = {}
      #      Run.where(:id => all_run_ids).all.each do |run|
      #       h_all_runs[run.id]=run
      #      end
      
      ## define if predictable = there is one matrix as input                                                                                                                                      
      matrix_runs = run_parents.select{|parent| parent[:type] == 'dataset'}
      predictable = (matrix_runs.size == 1) ? true : false
      if predictable# and ! h_var['nber_cols']
        matrix_run = matrix_runs.first
        if matrix_run and matrix_run[:output_json_filename]
          h_output_json = JSON.parse(File.read(project_dir + matrix_run[:output_json_filename]))
          h_var['nber_cols'] ||= h_output_json['nber_cols'] if h_output_json['nber_cols']
          h_var['nber_rows'] ||= h_output_json['nber_rows'] if h_output_json['nber_rows']
        end
      end
      
      list_args = []
      if h_p[:h_cmd_params]['args']
          h_p[:h_cmd_params]['args'].each do |h_arg|
          logger.debug "H_ARG: " + h_arg.to_json
          std_method_attr = h_std_method_attrs[h_arg['param_key']]
          raw = h_arg['value'] || h_var[h_arg['param_key']] || ((std_method_attr) && std_method_attr['default'])
          logger.debug "VALUE: " + raw.to_json + "[" + h_arg['value'].to_json + "]"
          # Use gsub instead of gsub! to avoid frozen string errors, and ensure we have a mutable string
          value_str = raw.nil? ? ''.dup : raw.to_s.dup
          value = value_str.gsub(/(\#\{[\w_]+?\})/) { |var| h_var[var[2..-2]] }
          next if skip_command_json_arg_or_opt_entry?(h_arg, h_var, p, value)

          list_args.push({:param_key => h_arg['param_key'], :value => (value != nil and value != '') ? value : h_arg["null_value"]})
        end
      end
      
      list_opts = []
      if h_p[:h_cmd_params]['opts']
        h_p[:h_cmd_params]['opts'].each do |opt|
          std_method_attr = h_std_method_attrs[opt['param_key']]
          raw = opt['value'] || h_var[opt['param_key']] || (std_method_attr && std_method_attr['default'])
          logger.debug "VALUE: #{opt}: " + raw.to_json
          # Use gsub instead of gsub! to avoid frozen string errors, and ensure we have a mutable string
          value_str = raw.nil? ? ''.dup : raw.to_s.dup
          value = value_str.gsub(/(\#\{[\w_]+?\})/) { |var| h_var[var[2..-2]] }
          next if skip_command_json_arg_or_opt_entry?(opt, h_var, p, value)

          if command_json_boolean_truthy?(opt['valueless_flag'])
            list_opts.push({:opt => opt['opt'], :param_key => opt['param_key'], :value => ''})
            next
          end

          list_opts.push({:opt => opt['opt'], :param_key => opt['param_key'], :value => (value != nil and value != '') ? value : opt["null_value"]})
        end
      end
      
      host_name =  h_p[:h_cmd_params]['host_name'] || 'localhost'
      container_name = ENV.fetch('ASAP_INSTANCE_NAME') + "_" + run.id.to_s
      
      #      logger.debug "ATTRS_json: " + h_p[:h_attrs].to_json
      #      logger.debug "H_VAR: " + h_var.to_json

      docker_image_key = docker_image.to_s.strip.presence
      unless docker_image_key
        h_res[:error] = 'command_json is missing docker_image after merging step and std_method command_json.'
        return h_res
      end

      h_images = h_p[:h_env]['docker_images']
      unless h_images.is_a?(Hash)
        h_res[:error] = 'version env_json has no docker_images hash.'
        return h_res
      end

      h_env_docker_image = h_images[docker_image_key]
      unless h_env_docker_image.is_a?(Hash)
        known = h_images.keys.join(', ')
        h_res[:error] = "command_json docker_image is #{docker_image_key.inspect} but env_json docker_images defines only: #{known}"
        return h_res
      end

      logger.debug(h_env_docker_image.to_json)
      image_name = h_env_docker_image['name'] + ":" + h_env_docker_image['tag']
      docker_build = DockerBuild.find_or_create_for_image_ref!(image_name)
      h_cmd = {
        :host_name => host_name,
        :container_name => container_name,
        :docker_call => (docker_image) ? h_env_docker_image['call'].gsub(/\#image_name/, image_name) : nil,
        :time_call => h_p[:h_env]['time_call'].gsub(/(\#[\w_]+)/) { |var| h_var[var[1..-1]] },
        :exec_stdout =>  h_p[:h_env]['exec_stdout'].gsub(/(\#[\w_]+)/) { |var| h_var[var[1..-1]] },
        :exec_stderr =>  h_p[:h_env]['exec_stderr'].gsub(/(\#[\w_]+)/) { |var| h_var[var[1..-1]] },
        :program =>  h_p[:h_cmd_params]['program'],
        :args => list_args,
        :opts => list_opts
      }
      h_cmd[:db_json] = db_json_cmd_meta if db_json_cmd_meta

      if predictable
        
        h_predict_params = {}
        h_p[:h_cmd_params]['predict_params'].each do |pp|
          h_predict_params[pp] = h_var[pp]
        end
        
        h_cmd[:expected_duration] = Basic.predict_duration(h_predict_params)
        h_cmd[:expected_ram] = Basic.predict_ram(h_predict_params)
      end

  #    logger.debug "CMD_JSON" + h_cmd.to_json

      run_parents_to_save = []
      run_parents.each do |e|
        h_parent = {}
        [:run_id, :type, :output_attr_name, :input_attr_name].each do |k2|
          h_parent[k2] = e[k2]
        end
        run_parents_to_save.push(h_parent)
      end

      ### predict max_ram and process_duration
      h_pred_results = {}
   #   logger.debug "H_VARS: " + h_var.to_json
   #   logger.debug "docker run --entrypoint '/bin/sh' --rm -v /data/asap2:/data/asap2 -v /srv/asap_run/srv:/srv fabdavid/asap_run:v#{h_p[:project].version_id} -c 'Rscript prediction.tool.2.R predict /data/asap2/pred_models/#{h_p[:project].version_id} #{run.std_method_id} " + "#{h_var['nber_rows']} #{h_var['nber_cols']} 2>&1'"
      if h_var['nber_rows'] and h_var['nber_cols']
        version = h_p[:project].version
        asap_docker_image = get_asap_docker(version)
        asap_docker_name = "fabdavid/asap_run:#{asap_docker_image.tag}"
#        cmd = "docker run --entrypoint '/bin/sh' --rm -v /data/asap2:/data/asap2 -v /srv/asap_run/srv:/srv fabdavid/asap_run:v#{h_p[:project].version_id} -c 'Rscript prediction.tool.2.R predict /data/asap2/pred_models/#{h_p[:project].version_id} #{run.std_method_id} " + "#{h_var['nber_rows']} #{h_var['nber_cols']} 2>&1'"
        vol = Basic.prediction_docker_volume_mount_arg
        models_base = Basic.prediction_models_path_for_r
        # Do not mount over /srv: prediction.tool.2.R ships in the asap_run image WORKDIR (/srv).
        cmd = "docker run --entrypoint '/bin/sh' --rm #{vol} #{asap_docker_name} -c 'Rscript prediction.tool.2.R predict #{models_base}/#{h_p[:project].version_id} #{run.std_method_id} " + "#{h_var['nber_rows']} #{h_var['nber_cols']} 2>&1'"
            logger.debug("PRED_CMD: #{cmd}")
        pred_results_json = `#{cmd}`.split("\n").first #.gsub(/^(\{.+?\})/, "\1")                                                                                                       
        h_pred_results = Basic.safe_parse_json(pred_results_json, {})
      end
      
      h_upd = {
        :status_id => 1,
        :pred_max_ram => (h_pred_results['predicted_ram'] != 'NA') ? h_pred_results['predicted_ram'] : nil ,
        :pred_process_duration => (h_pred_results['predicted_time'] != 'NA') ?  h_pred_results['predicted_time'] : nil,
        :attrs_json => new_h_attrs.to_json,
        :command_json => h_cmd.to_json,
        :docker_build_id => docker_build.id,
        :run_parents_json => run_parents_to_save.to_json,        
        :lineage_run_ids => (run_parents and run_parents.size > 0) ? (run_parents.map{|e| e[:lineage_run_ids].split(",").map{|e| e.to_i}}.flatten + run_parents.map{|e| e[:run_id]}).uniq.sort.join(",") : ""
      }

      logger.debug("H_UPD:" + h_upd.to_json)

      Basic.upd_run h_p[:project], run, h_upd, true
      #  run.update({
      #                          #                              :host_name => host_name,
      #                          #                              :container_name => container_name, 
      #                          :command_json => h_cmd.to_json, 
      #                          :run_parents_json => run_parents.to_json
      #                        });
      
      return h_res
      
    end

#    def init_active_run run    
#      h_res = {}
#      h_active_run = run.as_json
#      h_active_run[:run_id] = run.id
#      ar = ActiveRun.new(h_active_run)
#      ar.save!
#      return h_res
#    end

    def predict_ram h_predict_param
      return nil
    end

    def predict_duration h_predict_param
      return nil
    end

    # Body passed to sh -c for SLURM/docker execution (program, opts, args, redirects).
    def core_command_shell_body_for_run(h_cmd)
      return '' unless h_cmd.is_a?(Hash)

      h_cmd = h_cmd.dup
      h_cmd['opts'] ||= []
      h_cmd['args'] ||= []
      cmd_parts = [
        h_cmd['program'],
        h_cmd['opts'].map { |e| command_json_opt_shell_fragment(e) }.join(' '),
        h_cmd['args'].map { |e| safe_cmdline_param(e['value']) }.join(' '),
        (h_cmd['exec_stdout']) ? "1> #{h_cmd['exec_stdout']}" : nil,
        (h_cmd['exec_stderr']) ? "2> #{h_cmd['exec_stderr']}" : nil
      ]
      cmd_parts.compact.join(' ')
    end
    private :core_command_shell_body_for_run

    # Same shell body as RunExecutionJob previously built; kept for SLURM worker and docker wrapping.
    def build_run_core_command(h_cmd)
      h_cmd = h_cmd.dup
      h_cmd['opts'] ||= []
      h_cmd['args'] ||= []
      shell_body = core_command_shell_body_for_run(h_cmd)
      cmd = "sh -c '" + shell_body + "'"
      cmd = [h_cmd['time_call'], cmd].join(' ') if h_cmd['time_call'].present?
      cmd
    end

    # Human-readable program line for run pages (no docker run, no sh -c wrapper).
    # Omits time_call prefix and stdout/stderr redirects (1> / 2>) for a concise card.
    def run_inner_command_display_string(command_json)
      h_cmd = safe_parse_json(command_json, {})
      return nil unless h_cmd.is_a?(Hash) && h_cmd['program'].present?

      h_display = h_cmd.dup
      h_display['exec_stdout'] = nil
      h_display['exec_stderr'] = nil
      shell_body = core_command_shell_body_for_run(h_display)
      return nil if shell_body.blank?

      shell_body.strip
    end

    def build_docker_cmd h_cmd, core_cmd
      cmd = core_cmd

      # Rails commands should run in the website container, not in asap_run container
      # SLURM will wrap them in docker exec asap2_test-website-1
      if h_cmd['program'] && h_cmd['program'].start_with?('rails')
        return cmd
      end

      if h_cmd['docker_call']
        docker_call = h_cmd['docker_call'].dup
        docker_call = docker_call.dup if docker_call.frozen?
        normalize_legacy_docker_call!(docker_call)
        docker_call = substitute_docker_call_placeholders!(docker_call, h_cmd, core_cmd)
        cmd = docker_call + " \"" + core_cmd + "\""
      end
      cmd
    end

    # Strip deployment-specific fragments from legacy env_json templates before placeholder substitution.
    def normalize_legacy_docker_call!(docker_call)
      docker_call.gsub!(/\s*-v \/srv\/asap_run\/srv:\/srv\s*/, ' ')
      docker_call.gsub!(/\s*-v \/data\/asap2?:\/data\/asap2?\s*/, ' ')
      docker_call.gsub!(/\s*--env-file\s+\.env_asap_run\s*/, ' ')
      docker_call.gsub!(/\s*--env-file\s+\/data\/asap[^ ]*\.env_asap_run\s*/, ' ')
    end
    private :normalize_legacy_docker_call!

    def substitute_docker_call_placeholders!(docker_call, h_cmd, core_cmd)
      host_option = h_cmd['host_name'] != 'localhost' ? "-H #{h_cmd['host_name']}" : ''
      run_network = ENV['ASAP_RUN_DOCKER_NETWORK'].to_s.strip
      required_mount = user_data_docker_volume_mount_arg
      env_file_option = docker_call.include?('#env_file_option') ? asap_run_env_file_docker_option : ''

      docker_call = docker_call.dup
      docker_call.gsub!(/\#container_name/, h_cmd['container_name'] || '')
      docker_call.gsub!(/\#host_option/, host_option)
      docker_call.gsub!(/\#user_data_mount/, required_mount)
      docker_call.gsub!(/\#env_file_option/, env_file_option)

      if docker_call.include?('#run_network')
        raise 'ASAP_RUN_DOCKER_NETWORK is missing. Set it in the env file loaded by docker-compose for website/sidekiq, then restart those services.' if run_network.blank?

        docker_call.gsub!(/\#run_network/, run_network)
      else
        has_network_flag = docker_call.match?(/--network(?:=|\s+)\S+/)
        uses_legacy_network = docker_call.match?(/--network(?:=|\s+)asap2_asap_network(?:\s|$)/)
        if run_network.present? && has_network_flag
          docker_call.gsub!(/--network(?:=|\s+)\S+/, "--network=#{run_network}")
        elsif uses_legacy_network
          raise 'ASAP_RUN_DOCKER_NETWORK is missing. Set it in the env file loaded by docker-compose for website/sidekiq (for example: ASAP_RUN_DOCKER_NETWORK=asap2_test_default), then restart those services.'
        end
      end

      if !docker_call.include?(required_mount)
        docker_call.sub!(/^docker run\s+/, "docker run #{required_mount} ")
      end

      if core_cmd.include?('host.docker.internal') && !docker_call.include?('host.docker.internal:host-gateway')
        docker_call.sub!(/^docker run\s+/, 'docker run --add-host=host.docker.internal:host-gateway ')
      end

      docker_call
    end
    private :substitute_docker_call_placeholders!

    def command_json_opt_shell_fragment(entry)
      opt = entry['opt']
      val = entry['value']
      return opt.to_s if val.nil? || val.to_s.strip == ''

      "#{opt} #{safe_cmdline_param(val)}"
    end
    private :command_json_opt_shell_fragment

    def safe_cmdline_param p
      p = p.to_s
      contains_quotes = false
      if p.match(/["']/)
        contains_quotes = true
      end
      if p.match(/['"<>\s]/) 
        p = "\"#{p}\""
        p.gsub!(/(["])/){|var| "\\#{var}"}
      end
      if p == ';'
        p = "\\;"
      end
      return p
    end

    def build_cmd h_cmd
      puts "H_CMD: " + h_cmd.to_json
      h_cmd['opts']||=[]
      h_cmd['args']||=[]
      puts "H_CMD: " + h_cmd.to_json
      
      # For rails commands, add working directory and environment setup
      program_cmd = if h_cmd['program'] && h_cmd['program'].start_with?('rails')
        rails_root = Rails.root.to_s
        rails_env = Rails.env
        "cd #{rails_root} && RAILS_ENV=#{rails_env} bundle exec #{h_cmd['program']}"
      else
        h_cmd['program']
      end
      
      cmd_parts = [
                   program_cmd,
                   h_cmd['opts'].map { |e| command_json_opt_shell_fragment(e) }.join(" "), 
                   h_cmd['args'].map{|e| safe_cmdline_param(e['value'])}.join(" "),
                   (h_cmd['exec_stdout']) ? "1> #{h_cmd['exec_stdout']}" : nil,
                   (h_cmd['exec_stderr']) ? "2> #{h_cmd['exec_stderr']}" : nil
                  ]
      cmd = "sh -c '" + cmd_parts.compact.join(" ") + "'" 
      
      cmd_core = [h_cmd['time_call'], cmd].compact.join(" ") 
      #  h_cmd['program'], 
      #              h_cmd['opts'].map{|e| "#{e['opt']} #{e['value']}"}.join(" "), h_cmd['args'].map{|e| e['value']}].compact.join(" ")
      puts "CMD_CORE: " + cmd_core
      cmd = build_docker_cmd(h_cmd, cmd_core)
      #      if h_env['docker_call']
      #        cmd = h_env['docker_call'] + "\"" + cmd_core + "\""
      #      end
      return cmd
    end

    def file_matches? output_dir, k, h_expected_outputs, filename, filepath
      exp_filename = h_expected_outputs[k]['filename'] if h_expected_outputs[k]['filename']
      exp_filename_regexp = output_dir + h_expected_outputs[k]['filename_regexp'] if h_expected_outputs[k]['filename_regexp']
      exp_filepath_regexp = output_dir + h_expected_outputs[k]['exp_filepath_regexp'] if h_expected_outputs[k]['exp_filepath_regexp']
      puts "CHECK: #{k}, #{filename}, #{exp_filename}"
      return (exp_filename and filename and  filename == exp_filename)
      #(exp_filename or exp_filename_regexp or exp_filepath_regexp) and (!exp_filename or filename == exp_filename)
      #  and (!exp_filename_regexp or filename.match(/#{exp_filename_regexp}/)) and 
      # (!exp_filepath_regexp or filepath.match(/#{exp_filepath_regexp}/))
      #       )
    end

    def update_h_output_files h, annot
      ### update dataset_size, nber_cols, nber_row from added annots
      h['nber_cols'] = annot.nber_cols
      h['nber_rows'] = annot.nber_rows
      h['dataset_size'] = annot.mem_size
      return h
    end

    def exec_run_sync_stdout logger, run
      
      start_time = Time.now
      
      project = run.project
      version = project.version
      step = run.step
      project_step = ProjectStep.where(:project_id => project.id, :step_id => step.id).first

      h_data_types = {}
      DataType.all.map{|dt| h_data_types[dt.name] = dt}

      h_upd = {
        :status_id => 2,
        :start_time => start_time,
        :waiting_duration => start_time - run.created_at #submitted_at                                                                                                               
      }
      upd_run project, run, h_upd, true
      project.broadcast step.id

      ## define output_dir                                                                                                                                                          

      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
      step_dir = project_dir + step.name
      Dir.mkdir step_dir if !File.exist? step_dir
      output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir

      Dir.mkdir output_dir if !File.exist? output_dir
      
      h_cmd = JSON.parse(run.command_json)
      
      cmd = build_cmd(h_cmd)
      logger.debug("CMD:#{cmd}")
      puts "CMD: " + cmd
    #  pid = spawn(cmd)
      h_results = `#{cmd}`
      finish_run logger, run, h_results
      
      return h_results
      
    end

    def exec_run logger, run
      if run.async == false
        exec_run_sync logger, run
      else
        exec_run_async logger, run
      end
    end

    def exec_run_async logger, run
      unless [1, 6].include?(run.status_id.to_i)
        logger.warn("Run##{run.id} is not in schedulable status (current: #{run.status_id}), skipping")
        return nil
      end

      # Mark as scheduler-submitted to avoid duplicate enqueue loops from polling endpoints.
      if run.status_id.to_i == 1
        run.update(
          status_id: 6,
          submitted_at: Time.now,
          waiting_duration: nil
        )
      end

      logger.info("Submitting Run##{run.id} to SLURM via RunExecutionJob")
      # Execute submission immediately so runs are not blocked on async in-process job workers.
      # This job only prepares and submits to SLURM, then schedules monitoring separately.
      RunExecutionJob.perform_now(run.id)
      return nil
    end

    def exec_run_sync logger, run
      start_time = Time.now
      
      project = run.project
      version = project.version
      step = run.step
      puts "run_id:#{step.id}"
      project_step = ProjectStep.where(:project_id => project.id, :step_id => step.id).first

      h_data_types = {}
      DataType.all.map{|dt| h_data_types[dt.name] = dt}

      h_upd = {
        :status_id => 2,
        :start_time => start_time,
        :waiting_duration => start_time - run.created_at #submitted_at
      }
      upd_run project, run, h_upd, true
      project.broadcast step.id

      puts "toto!!!!"

      ## define output_dir                                                                                                                                                                   
      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
      step_dir = project_dir + step.name
      Dir.mkdir step_dir if !File.exist? step_dir
      output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir

      Dir.mkdir output_dir if !File.exist? output_dir

      ## initialize directoy: remove files but keep directories (directory ./input contains things added previously from an interaction with the browser) 
      Dir.new(output_dir).entries.select{|f| File.directory?(f) == false}.each do |f|
        #  File.delete output_dir + f  ### do not delete finally because we cannot run again a given run   
      end
      
      h_attrs = JSON.parse(run.attrs_json)
      
      res = ''

      ## define abort conditions
      abort = nil
      logger.debug("Before ABORT!")
      if step.name == 'dim_reduction' and h_attrs['nber_dims'] == 3
        h_annot = {
          :run_id => h_attrs['input_matrix']['run_id'],
          :filepath =>  h_attrs['input_matrix']['output_filename'], 
          :name => h_attrs['input_matrix']['output_dataset']
        }
        if h_attrs['input_matrix']['annot_id'] 
          h_annot = {:id => h_attrs['input_matrix']['annot_id']}
        end
        annot = Annot.where(h_annot).first
        logger.debug "CHECK ABORT: " + annot.to_json
        if annot and annot.nber_cols and annot.nber_cols > 500000
          logger.debug("ABORT!")
          abort = "Too many cells (>500'000) to perfom a 3D dimension reduction"
        end
      end
      
      ## execute command                                                                                                                                                                    

      hca_output_json_file = project_dir + 'parsing' + "get_loom_from_hca.json"
      h_output_hca = Basic.safe_parse_json(File.read(hca_output_json_file), {}) if File.exist? hca_output_json_file

      all_displayed_errors = []

      if !abort and (!h_output_hca or h_output_hca['status_id'] !=4)

        h_cmd = Basic.safe_parse_json(run.command_json, {})
        puts "H_CMD: #{run.command_json} #{h_cmd.to_json}"
        if h_cmd.keys.size == 0
          all_displayed_errors.push("Not valid command")
        else
          cmd = build_cmd(h_cmd)
          logger.debug("CMD:#{cmd}")
          if run.return_stdout == true
            res = `#{cmd}`
          else
            puts "CMD: " + cmd
            pid = spawn(cmd)
            Process.waitpid(pid)
          end
        end
      elsif abort
        all_displayed_errors = [abort]
      elsif h_output_hca and h_output_hca['error']
        all_displayed_errors = ["Error from HCA: " + h_output_hca['error']]
      end

      output_json_filename = output_dir + 'output.json'
      h_results = {}
      if run.return_stdout == true
        h_results = Basic.safe_parse_json(res, {})
      elsif File.exist? output_json_filename
        h_results = Basic.safe_parse_json(File.read(output_json_filename), {})
      end
      
      if ! ($? and ! $?.stopped?) or h_results.is_a?(Hash) == false or h_results.keys.size == 0
        status_id = 4
        if all_displayed_errors.size > 0
          h_results['displayed_error'] = all_displayed_errors 
        else
          h_results['displayed_error'] = ['Stopped']
        end
        #        commit_finished_run logger, run, h_results, h_output_files
      end
      
      #### patch
      if step.id == 16
        h_results = {"metadata" => [h_results]}
      end

      h_results = finish_run logger, run, h_results

      return (run.return_stdout == true) ? res : nil

    end
    
    def finish_run logger, run, h_results, skip_broadcast: false
      
      logger.info("[Basic.finish_run] Starting for Run##{run.id}, Project##{run.project_id}")
      logger.debug("[Basic.finish_run] h_results keys: #{h_results.keys.inspect}")
      
      #      start_time = Time.now
      run = Run.find(run.id)
      project = run.project
      version = project.version
      asap_docker_image = get_asap_docker(version)
      step = run.step
      project_step = ProjectStep.where(:project_id => project.id, :step_id => step.id).first
      
      ## check if the project is not archived, and if it is unarchive first                                                                
      if project.archive_status_id == 3
        #   cmd = "rails unarchive[#{project.key}]"
        #   `#{cmd}`
        Basic.unarchive(project.key)
      end
#      while project = run.project and project.archive_status_id != 1
#        sleep 1
#      end
      
      h_data_types = {}
      DataType.all.map{|dt| h_data_types[dt.name] = dt}

      h_data_classes = {}
      DataClass.all.map{|dt| h_data_classes[dt.name] = dt;  h_data_classes[dt.id] = dt}
      
      h_steps = {}
     # Step.where(:version_id => project.version_id).all.each do |s|
      Step.where(:docker_image_id => asap_docker_image.id).all.each do |s| 
        h_steps[s.id] = s
      end
      
      h_runs = {}
      project.runs.select{|r| r.status_id == 3}.each do |run|
        h_runs[run.id] = run
      end
      
      start_time = run.start_time
  
#      h_upd = {
#        :status_id => 2, 
#        :start_time => start_time, 
#        :waiting_duration => start_time - run.submitted_at
#      }
#      upd_run project, run, h_upd
#      project.broadcast step.id
     
      ## define output_dir
      project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key 
      step_dir = project_dir + step.name
      Dir.mkdir step_dir if !File.exist? step_dir
      output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
      
      Dir.mkdir output_dir if !File.exist? output_dir
      
      ## initialize directoy: remove files but keep directories (directory ./input contains things added previously from an interaction with the browser)
      Dir.new(output_dir).entries.select{|f| File.directory?(f) == false}.each do |f|
      #  File.delete output_dir + f  ### do not delete finally because we cannot run again a given run
      end

      h_attrs = JSON.parse(run.attrs_json)
      
      ## execute command

      h_var = { 
        'user_id' => project.user_id,
        'project_dir' => project_dir,
        'output_dir' => output_dir, #project_dir + step.name + run.id.to_s,
        'step_tag' => step.tag,
        'std_method_name' => (std_method = run.std_method) ? std_method.name : step.name,
        'std_method_label' => (std_method = run.std_method) ? std_method.label : step.label,
        'std_method_short_label' => (std_method = run.std_method) ? (std_method.short_label.presence || std_method.name) : step.name,
        'run_num' => run.num
      }

      hca_output_json_file = project_dir + 'parsing' + "get_loom_from_hca.json"
      h_output_hca = Basic.safe_parse_json(File.read(hca_output_json_file), {}) if File.exist? hca_output_json_file
      all_displayed_errors = []
      if h_results['displayed_error'].is_a?(Array)
        all_displayed_errors = h_results['displayed_error']
      elsif h_results['displayed_error'].is_a?(String)
        all_displayed_errors.push h_results['displayed_error']
      end
      #      if !h_output_hca or h_output_hca['status_id'] !=4
      
      h_env = Basic.safe_parse_json(version.env_json, {})
puts "TEST RUN"
      puts run.to_json
      h_cmd = Basic.safe_parse_json(run.command_json, {})     
      #      puts h_cmd.to_json
      
      ## add cmd arguments in h_var to get the output_matrix_filename
      if h_cmd['args']
        #       puts "ARGS: " + h_cmd["args"].to_json
        h_cmd['args'].each do |a|
          h_var[a["param_key"]] = a["value"]
        end
      end
      if h_cmd['opts']
        h_cmd['opts'].each do |a|
          h_var[a["param_key"]] = a["value"]
        end
      end
      
      #      ## check if expected output files exist                                                                                                                         
      #      h_output_json_db = JSON.parse(step.output_json)
      #      h_expected_outputs = (h_output_json_db) ? h_output_json_db['expected_outputs'] : nil
      
      ## compute size of files before run execution
      #      if h_expected_outputs
      #        h_file_size_before_exec = {}
      #        h_expected_outputs.each_key do |k|
      #          puts           h_expected_outputs[k].to_json
      #          if h_expected_outputs[k]["filepath"]          
      #            dataset_path = (h_expected_outputs[k]['dataset']) ? h_expected_outputs[k]['dataset'].gsub(/(\#\{[\w_]+?\})/) { |var| h_var[var[2..-2]] } : nil
      #            filepath = h_expected_outputs[k]["filepath"].gsub(/(\#\{[\w_]+?\})/) { |var| h_var[var[2..-2]] }
      #            if h_expected_outputs[k]["filepath"]
      #              h_file_size_before_exec[filepath] = File.size(filepath)
      #            end
      #          end
      #        end
      #      end
      
      #        cmd = build_cmd(h_cmd)
      #        logger.debug("CMD:#{cmd}")
      #        puts "CMD: " + cmd 
      #        pid = spawn(cmd)
      
      #  h_pids = {
      #    :in_docker => nil,
      #    :cmd => nil
      #  }
      #  if h_env['docker_call']
      #    h_pids[:cmd] = tmp_pid
      #    in_docker_pid_file = output_dir + 'cmd.pid'
      #    h_pids[:in_docker] = File.read( cmd_pid_file) if File.exist? in_docker_pid_file
      #  else
      #    h_pids[:cmd] = tmp_pid
      #  end
      
      #        h_run = {
      #          #    :command_line => cmd,
      #          :status_id => 2,
      #          #    :in_docker_pid => h_pids[:in_docker],
      #          #    :cmd_pid => h_pids[:cmd]
      #          #    :pid = pid        
      #        }
      #        upd_run project, run, h_run
      #        #      run.update(h_run)
      #        project.broadcast run.step_id
      #        
      #        Process.waitpid(pid)
      #        
      #      else
      #        all_displayed_errors.push("Error from HCA: " + h_output_hca['error'])
      #      end
      
      #     logger.debug "CMD_STATUS: #{$?.stopped?}"
      
     # output_json_filename = output_dir + 'output.json'
      # h_results = {}
      
      #      if $? and ! $?.stopped?  #(job and ! $?.stopped?) or (results["original_error"] or results["displayed_error"])             
      
      ## check if expected output files exist                            
      h_output_json_db = Basic.safe_parse_json(step.output_json, {})
      h_expected_outputs = (h_output_json_db) ? h_output_json_db['expected_outputs'] : nil
      
      
      ## get list of files produced
      output_files = Dir.new(output_dir).entries.select{|e| !e.match(/^\./)}
      h_output_files = {}
      
      #        puts "output_files: #{output_files.to_json}"
      
      ## attribute files to expected output keys
      
      #        ## check if expected output files exist
      #        h_output_json_db = JSON.parse(step.output_json)        
      #        h_expected_outputs = (h_output_json_db) ? h_output_json_db['expected_outputs'] : nil
   
#      puts "H_OUTPUT_DB #{step.id} #{h_output_json_db.to_json}"
      puts "H_EXPECTED_OUTPUTS. #{h_expected_outputs.to_json}"
   
      onum = 1
      if h_expected_outputs
        h_expected_outputs.each_key do |k|
          
          dataset_path = (h_expected_outputs[k]['dataset']) ? h_expected_outputs[k]['dataset'].gsub(/(\#\{[\w_]+?\})/) { |var| h_var[var[2..-2]] } : nil
          
          #         puts "k: "+ k 
          ### check if the file is at the path if the expected path is not including the standard output directory                      
          
          if h_expected_outputs[k]["filepath"]
            #           puts "BLA22: " + h_expected_outputs[k]["filepath"]
          #  puts h_var.to_json
            #  dataset_path = (h_expected_outputs[k]['dataset']) ? h_expected_outputs[k]['dataset'].gsub(/(\#\{[\w_]+?\})/) { |var| h_var[var[2..-2]] } : nil
            filepath = h_expected_outputs[k]["filepath"].gsub(/(\#\{[\w_]+?\})/) { |var| h_var[var[2..-2]] }
       #     puts "COMPUTE_RELATIVE_PATH: #{project.id}, #{filepath}" 
            relative_filepath = relative_path(project, filepath)
            output_key = [relative_filepath, dataset_path].compact.join(":")
       #     puts "OUTPUT_KEY: #{output_key}"
            #            puts "FILEPATH22: " + filepath
            if File.exist? filepath
              h_output_files[k]||={}
              h_output_files[k][output_key]={ "onum" => onum, "filename" => File.basename(filepath), "dataset" => dataset_path, "types" => h_expected_outputs[k]["types"]}
              #  ["dataset"].select{|k2| h_expected_outputs[k][k2]}.each do |k2|
              #    h_output_files[k][filepath][k2] = h_expected_outputs[k][k2].gsub(/(\#\{[\w_]+?\})/) { |var| h_var[var[2..-2]] }
              #  end
            #              puts "H_OUTPUT_FILE22: " + h_output_files[k].to_json
              onum+=1
            end
          else
            ### check output files present in the standard output directory
            output_files.each do |filename|
              filepath = relative_path(project, output_dir + filename)  #[step.name, run.id, filename].join("/")
              #    dataset_path = (h_expected_outputs[k]['dataset']) ? h_expected_outputs[k]['dataset'].gsub(/(\#\{[\w_]+?\})/) { |var| h_var[var[2..-2]] } : nil
              output_key = [filepath, dataset_path].compact.join(":")
         #     puts "OUTPUT_KEY2: #{output_key}"
              if file_matches?(output_dir, k, h_expected_outputs, filename, filepath)   
                h_output_files[k]||={}
                h_output_files[k][output_key] ||= {"onum" => onum, "filename" => filename, "dataset" => dataset_path, "types" =>  h_expected_outputs[k]["types"]}            
                #   ["dataset"].select{|k2| h_expected_outputs[k][k2]}.each do |k2|
                #     h_output_files[k][filepath][k2] = h_expected_outputs[k][k2].gsub(/(\#\{[\w_]+?\})/) { |var| h_var[var[2..-2]] } 
                #   end
                
                onum+=1
                break
              end
            end
          end
          if !h_output_files[k]
            ### no files in the output directory
            if !h_expected_outputs[k]["optional"] or h_expected_outputs[k]["optional"] == false
              rendered_filename = (h_expected_outputs[k]["filename"]) ? h_expected_outputs[k]["filename"] : k
              if rendered_filename == 'output.json'
                all_displayed_errors.push("Something went wrong.") # : "#{rendered_filename} file is missing.") 
              end
              # all_displayed_errors.push( "#{rendered_filename} file is missing.")
            end
          end
        end
      end
      ## add output files not expected but indicated in the JSON as existing_metadata
      
      
      ### get unexpected files
      #output_files.each do |filename|
        #  filepath = output_dir + filename
      #  flag = 0
      #   h_output_files.each_key do |k|
      #    h_output_files[k].each_key do |f|
      #      flag== 1 if filepath == f
      #    end
      #  end
      #end
        
      #      puts "H_OUTPUT_FILES: #{h_output_files.to_json}" 
      #      puts "H_EXP_OUTPUT_FILES: #{h_expected_outputs.to_json}"
      #        results = {}
      
      #found_expected = true
      #h_expected_outputs.each_key do |k|
      #  filename = output_dir + h_expected_outputs[k]['filename']
      #  if !h_expected_outputs[k]['optional']
      #    found_expected = false if !File.exist? filename
      #          end
      #        end
      
      
      ### check if json results is parseable, if not write an error to be complemented
      #if File.exist? output_json_filename
      #  begin
      #    h_results = JSON.parse(File.read(output_json_filename))          
      #    all_displayed_errors.push(h_results['displayed_error']) if h_results['displayed_error']
      #  rescue Exception => e
      #    #         puts "BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD"
      #    all_displayed_errors.push('Bad JSON format of results file output.json' + e.message)
      #  end
      #  #      puts "DISPLAYED_ERROR: " + all_displayed_errors.to_json
      #end
      #    puts "DISPLAYED_ERROR2: " + all_displayed_errors.to_json
      
      h_json_data = {}
      
      #        if all_displayed_errors.size == 0
      
      ### TRY TO DO WITHOUT DESCRIBING OUTPUTS IN THE JSON FILE
      ### get results
      #          if h_results['outputs']
      #            h_results['outputs'].each_key do |k|
      #              h_results['outputs'][k].each_key do |filepath|
      #                filename = filepath.split("/").last
      #                errors = []
      #                prop = h_results['outputs'][k][filepath]
      #                
      #               ## update types to the ones described in results                          
      #               h_output_files[k][f]["types"] = prop["types"] if prop["types"]
      #                
      #                ## k exists but file doesnt't match
      #                if h_output_files[k] 
      #                  if file_matches?(output_dir, k, h_expected_outputs, filename, filepath) == false
      #                    errors.push("#{f}: File doesn't match with filename description")
      #                  elsif !h_output_files[k][filepath] ## file matches constrains but not found in the output_dir directory => complete h_output_files
      #                    h_output_files[k][filepath] = prop
      #                  end
      #                end
      #                
      #                ## file not found in output directory
      #                if !h_output_files[k][filepath] and h_expected_outputs[k]["mandatory"]
      #                  error_txt = "#{f}: " + (h_expected_outputs[k]["mandatory"] == true) ? "File not found." : h_expected_outputs[k]["mandatory"]
      #                  errors.push(error_txt)
      #                end
      #            
      #                ### write error if exists
      #                if errors.size > 0
      #                  h_output_files[k][filepath]["errors"] = errors 
      #                  all_displayed_errors += errors
      #                end
      #                
      #              end
      #            end
      #          end
      
      ### check all files        
      
      #  h_json_data = {}
      
      no_error = true if  all_displayed_errors.size == 0
      
      h_output_files.each_key do |k|
        h_output_files[k].each_key do |k2|
          t = k2.split(":")
          relative_path = t[0]
          #            dataset_path = t[1] if t.size > 1
          
          filepath = project_dir + relative_path
          #       puts "FILEPATH:  " + filepath.to_s
          errors = []            
          ## compute size                                                                                                                                                       
          h_output_files[k][k2]["size"] = File.size(filepath)
          #            h_output_files[k][k2]["dataset_size"] = h_output_files[k][k2]["size"] - h_file_size_before_exec[filepath] if h_file_size_before_exec[filepath]
          ## check JSON errors               
          json_data = nil            
          # puts "BLAAAA_TYPES: #{h_output_files[k][k2]["types"]}"
          if h_output_files[k][k2]["types"].include?("json_file")
            begin
              json_data = JSON.parse(File.read(filepath))
              h_json_data[k] ||= {}
              h_json_data[k][filepath] = json_data ## only one json per output key allowed 
            rescue Exception => e
              #   puts "VERY BAAAAAAAAAAAAAAAAAAD" + e.backtrace.to_json
              errors.push('Bad JSON format')
            end
          end
          
          ## check size                                       
          
          #  puts "Check size of #{k} : #{h_output_files[k][k2]['size']} #{json_data.to_json}!"
          
          if (h_output_files[k][k2]["size"] == 0 or (h_output_files[k][k2]["types"].include?("json_file") and json_data and json_data.is_a? Hash and json_data.keys.size == 0)) and h_expected_outputs[k]["never_empty"]
            puts "Add error for #{k}!"
            error_txt = "#{h_output_files[k][k2]['filename']}: File is empty."
            errors.push(error_txt)
          end
          
          ### write error if exists       
          if errors.size > 0 and no_error == true
            h_output_files[k][k2]["errors"] ||=[]
            h_output_files[k][k2]["errors"] += errors
            all_displayed_errors += errors
          end
        end
      end
      
      ### replace outputs with h_output_files => to simplify debugging, finally just save in database
      #h_results['outputs'] = h_output_files
      
      #       end
      
#      h_output_json = (h_json_data['output_json'] and output_json_filename) ? h_json_data['output_json'][output_json_filename] : {}
      #  puts "H_OUTPUT_JSON: " + h_output_json.to_json
      
      ## get metadata by name
      h_metadata_by_name = {}
      if h_results['metadata']
        h_results['metadata'].each do |metadata|
          h_metadata_by_name[metadata['name']] = metadata
        end
      end

      loaded_annots = []
      logger.info("[Basic.finish_run] h_output_files keys: #{h_output_files.keys.inspect}")
      logger.debug("[Basic.finish_run] h_output_files: #{h_output_files.to_json}")
      finish_run_cache = {}
      finish_run_cache[:resolved_expected_datasets] = resolved_expected_output_datasets(step, h_var)
      input_dt_id = input_matrix_data_transformation_id_for_run(run, h_attrs, finish_run_cache)
      log_block = output_log_transform_block(h_results, step.name)
      output_log_specified = log_block.is_a?(Hash) && log_block.key?('is_log_transformed')
      if output_log_specified
        finish_run_cache[:data_transformation_from_output] = true
        finish_run_cache[:data_transformation_id] = data_transformation_id_from_log_attrs(log_block)
        logger.info("[Basic.finish_run] data_transformation_id=#{finish_run_cache[:data_transformation_id].inspect} from output log block")
      else
        finish_run_cache[:data_transformation_from_output] = false
        finish_run_cache[:data_transformation_id] = input_dt_id
        if input_dt_id
          logger.info("[Basic.finish_run] data_transformation_id=#{input_dt_id.inspect} inherited from input matrix")
        end
      end
      ## edit type of output_files in function of properties described in output.json
      ActiveRecord::Base.transaction do
        h_output_files.each_key do |k|
          h_output_files[k].each_key do |k2|           
            t = k2.split(":")
            relative_filepath = t[0]
            fo = create_upd_fo project.id, relative_filepath, finish_run_cache
            if h_output_files[k][k2]["types"].flatten.include?("dataset")
              filepath = project_dir + t[0]
              dataset_name = h_output_files[k][k2]["dataset"]
              if dataset_name
                if dataset_name == '/matrix' or dataset_name.match(/^\/layers\//)
                  matrix_dims = matrix_dims_from_results(h_results, dataset_name, h_metadata_by_name)
                  h_output_files[k][k2]["types"].push(matrix_dims['is_count'] ? "int_matrix" : "num_matrix")
                  h_output_files[k][k2]["nber_rows"] = matrix_dims['nber_rows']
                  h_output_files[k][k2]["nber_cols"] = matrix_dims['nber_cols']
                  h_output_files[k][k2]["dataset_size"] = matrix_dims['dataset_size']
                  
                  h_data = {
                    'output_attr_name' => k,
                    'nber_cols' => matrix_dims['nber_cols'],
                    'nber_rows' => matrix_dims['nber_rows'],
                    'type' => 'NUMERIC',
                    'data_class_names' => h_output_files[k][k2]["types"],
                    'on' => 'EXPRESSION_MATRIX',
                    'dataset_size' => matrix_dims['dataset_size'],
                    'name' => dataset_name,
                    'count' => matrix_dims['is_count']
                  }
                  logger.info("[Basic.finish_run] Creating matrix annotation: #{h_data.to_json}")
                  new_annot = load_annot(run, h_data, relative_filepath, h_data_types, h_data_classes, logger, finish_run_cache)
                  if new_annot
                    logger.info("[Basic.finish_run] Matrix annotation created: id=#{new_annot.id}, name=#{new_annot.name}, nber_rows=#{new_annot.nber_rows}, nber_cols=#{new_annot.nber_cols}")
                  else
                    logger.warn("[Basic.finish_run] load_annot returned nil for matrix annotation")
                  end
                  h_output_files[k][k2] = update_h_output_files(h_output_files[k][k2], new_annot) if new_annot
                  
                  if h_metadata_by_name.keys.size > 0
                    h_metadata_by_name.each_key do |meta_name|
                      next if meta_name == dataset_name

                      metadata = h_metadata_by_name[meta_name]
                      new_annot = load_annot(run, metadata, relative_filepath, h_data_types, h_data_classes, logger, finish_run_cache)
                      h_output_files[k][k2] = update_h_output_files(h_output_files[k][k2], new_annot) if new_annot
                    end
                  end
                elsif h_results['metadata'] and metadata = h_metadata_by_name[dataset_name]
                  h_output_files[k][k2]["nber_rows"] = metadata['nber_rows']
                  h_output_files[k][k2]["nber_cols"] = metadata['nber_cols']
                  h_output_files[k][k2]["dataset_size"] = metadata['dataset_size']
                  if metadata['type']
                    h_output_files[k][k2]["types"].push("#{metadata['type'].downcase}_mdata")
                  end
                  metadata['output_attr_name'] = k
                  metadata['data_class_names'] = h_output_files[k][k2]["types"]
                  new_annot = load_annot(run, metadata, relative_filepath, h_data_types, h_data_classes, logger, finish_run_cache)
                  h_output_files[k][k2] = update_h_output_files(h_output_files[k][k2], new_annot) if new_annot
                end
              end
            end
            if h_results['output_files'] and h_results['output_files'].is_a? Hash and h_results['output_files'][k2] and h_results['output_files'][k2]["types"]
              h_output_files[k][k2]["types"] |= h_results['output_files'][k2]["types"]
            end
          end
        end
      end
      

#      ### update dataset_size, nber_cols, nber_row from added annots
#      h_annots={}
#      loaded_annots.each do |annot|
#        output_key = "#{annot.filepath}:#{annot.name}"
#        h_annots[][output_key]
#      end

      h_results['displayed_error'] = all_displayed_errors.uniq if all_displayed_errors.size > 0
      
    #  commit_finished_run logger, run, h_results, h_output_files
      
      #h_outputs = {}
      ### fill h_outputs
      #        h_expected_outputs.each_key do |k|
      #          filename = output_dir + h_expected_outputs[k]['filename']
      #### dans le fichier output.json il faut decrire les fichiers qui sont produits - filename avec le chemin relatif dans le projet 
      #### !!!!!! NOT FINISHED => must be written in the output.json and used also in the block above
      #          if File.exist? filename
      #            h_outputs[k] = {:filename => filename, :type => results['outputs'][k]['type']})
      #          end
      #        end
      
      ### update duration    
      #      else
      #        status_id = 4
      #        h_results['displayed_error'] = all_displayed_errors if all_displayed_errors.size > 0
      #        h_results['displayed_error'].push('Stopped')
      #      end
      
#    end

#    def commit_finished_run logger, run, h_results, h_output_files

 #     start_time = run.start_time
 #     project = run.project
 #     version = project.version
 #     step = run.step
 #     project_step = ProjectStep.where(:project_id => project.id, :step_id => step.id).first

 #     ## define output_dir        
 #     project_dir = Pathname.new(ENV.fetch('USER_DATA_DIR')) + project.user_id.to_s + project.key
 #     step_dir = project_dir + step.name
 #     Dir.mkdir step_dir if !File.exist? step_dir
 #     output_dir = (step.multiple_runs == true) ? (step_dir + run.id.to_s) : step_dir
   
      time_info_filename = output_dir + 'exec_run_details.log'
      timing = parse_exec_run_details(time_info_filename)
      h_time_info = timing[:time_info] || {}
      process_duration = timing[:process_duration_seconds]
      logger.debug("TIME_INFO: " + h_time_info.to_json) if h_time_info.any?

      duration = (start_time) ? (Time.now - start_time) : nil 

      #  puts "OUTPUT_JSON = " +  h_output_files.to_json                                                                                                                                             
      status_id = (!h_results["original_error"] and !h_results["displayed_error"]) ? 3 : 4

      ### check if it might be a problem of memory
      #puts "BLA"
      if status_id == 4
        begin
          d = `free -b 2>/dev/null`
          lines = d.to_s.split(/\n/)
          if lines.size > 1
            free_mem = lines[1].to_s.split(/\s+/)[6]
            if free_mem
              diff = free_mem.to_i - h_time_info['M'].to_i
              if diff < 10000000
                h_results["displayed_error"] ||= []
                h_results["displayed_error"].push 'Probably out of RAM. The method you are using is probably not scalable to high dimensional datasets. Please try another more scalable method (using RAM prediction tool.'
              end
            end
          end
        rescue => e
          logger.warn("[Basic.finish_run] Could not check free memory: #{e.message}")
        end
      end

      ### write final results                    
      if run.return_stdout == false
        output_json_filename = output_dir + 'output.json'
        if File.exist? output_json_filename and h_results['displayed_error'] and h_results['displayed_error'].include?('Bad JSON format')
          FileUtils.cp output_json_filename, (output_dir + 'output.json.bad')
        end
        File.open(output_json_filename, 'w') do |f|
          f.write(h_results.to_json)
        end
      end
      
      ### compute_pred_params
      h_pred_params = set_predict_params(project, run, std_method, h_runs, h_steps)

      max_ram_mb = timing[:max_ram_mb]

      h_upd = {
        :output_json => h_output_files.to_json,
        :status_id => status_id,
        :duration => duration,
        :waiting_duration => (start_time && run.submitted_at) ? (start_time - run.submitted_at) : nil,
        :process_duration => process_duration, #h_time_info['E'].split(":"),                                      
        :process_idle_duration => h_results['time_idle'],
        :max_ram => max_ram_mb,
        :pred_params_json => h_pred_params.to_json
      }


      #      run && run.update(h_upd)
      #      h_project_step =  Basic.get_project_step_details(project, step.id)
      #      project_step.update(h_project_step)                                                                                                              
      if run
        upd_run(project, run, h_upd, true)
        # Reload run after update to ensure status is persisted
        run.reload
        Rails.logger.info("[Basic.finish_run] Run##{run.id} status after update: #{run.status_id}")
      end
      upd_project_size project
      if run && !skip_broadcast
        # Run-level push so clients can update the specific row directly; it
        # also carries the same step-level payload as project.broadcast(step_id)
        # did, keeping the left panel and header in sync.
        run.broadcast_status_change
      end
      return h_results
    end
    
    def std_run(run)
      h = {:project_id => project.id, :step_id => step_id,  :status_id => 1, :speed_id => speed_id}
      job = Job.new(h)
      job.save
      o.update({job_id_key => job.id, :status_id => 1})
      return job
    end

    def create_job(o, step_id, project, job_id_key, speed_id = 1)
      h = {:project_id => project.id, :step_id => step_id,  :status_id => 1, :speed_id => speed_id}
      job = Job.new(h)
      job.save
      o.update({job_id_key => job.id, :status_id => 1})
      return job
    end
    
    def finish_step(logger, start_time, project, step_id, o, output_file, output_json)
      
      project_step = ProjectStep.where(:project_id => project.id, :step_id => step_id).first

      #      logger.debug("BLA")

      ### check if there is not a step < 4 that is also < current project step that was updated after the last update of this step.
      
      #project_steps = ProjectStep.where("project_id = #{project.id} and step_id < 4 and step_id < #{step_id}")
      #alert = 0
      #project_steps.each do |ps|
      #  if ps.updated_at > project_step.updated_at
      #    alert = 1
      #    break
      #  end
      #end
      
      #if alert == 0
      
      results = {}
      if output_json and File.exist?(output_json)
        begin
          results = JSON.parse(File.read(output_json))
        rescue Exception => e
        end
      end

      logger.debug("JSON1: #{results.to_json}")

      duration = Time.now - start_time
      if File.exist?(output_file) and !results["original_error"] and !results["displayed_error"]
        logger.debug("SUCCESSFUL #{o.id}")
        o.update(:duration => duration, :status_id => 3)       
        if step_id != 4
          project.update(:duration => duration, :status_id => 3)
          project_step.update(:status_id => 3)
        end
      else
        logger.debug("FAILED #{o.id}")
        o.update(:duration => duration, :status_id => 4)
        if step_id != 4 and project_step.status_id != nil ## second part of condition to prevent to update project_step when a job is killed when an earlier step is restarted (necessary if the kill is slower than the update of the ps.status to nil)
          project.update(:duration => duration, :status_id => 4)
          project_step.update(:status_id => 4)
        end
      end
      
      project.broadcast step_id
      # end
    end
    
    def kill_job(logger, job)
      pid = (job) ? job.pid : nil
      if job 
        delayed_job = Delayed::Job.where(:id => job.delayed_job_id).first
        ### delete the job and delayed job if they are pending
        if job.status_id == 1
          delayed_job.destroy if delayed_job
          job.destroy        
        else
          if pid and `ps -ef | egrep '^rvmuser +#{pid} +' | wc -l`.to_i > 0
            
            ## kill main process                                                                                                                                                                                                                                                
            Process.kill('INT', pid) #Process::kill 0, job.pid                                                                                                                                                                                                              
            ## kill remaining children processes                                                                                                                                                                                                                                 
            processes = Sys::ProcTable.ps.select{ |pe| pe.ppid == pid }
            logger.debug("KILL CHILDREN: #{processes.map{|pe| pe.pid}}")
            processes.each do |pe|
              Process.kill('INT', pe.pid)
          end
            job.update(:status_id => 5)
            delayed_job.destroy if delayed_job
          end
        end
      end
    end

#    def kill_pid(docker_call, pid)
#      cmd_core = "kill -9 #{pid}"
#      cmd = build_docker_cmd(docker_call, docker_run_name, cmd_core)
#      `#{cmd}`
#    end
    
#    def get_children_pids(docker_call, pid)
#      cmd_core = "pgrep -P #{pid}"
#      cmd = build_docker_cmd(docker_call, docker_run_name, cmd_core)
#      return `#{cmd}`.split("\n")
#    end

    def is_running run
      h_cmd = JSON.parse(run.command_json)
      h_containers = list_containers(h_cmd['host_name'])
      is_running = false
      if h_containers[h_cmd['container_name']]
        is_running = true
      end
      return is_running
    end

    def list_containers(host_name)
      host_opt = (host_name == 'localhost') ? "" : "-H #{host_name}"
      cmd = "docker ps #{host_opt} --format '{{.Names}}\t{{.Image}}'"
      h_containers = {}
      list = `#{cmd}`.split("\n")
      list.each do |e|
        t = e.split("\t")
        h_containers[t[0]]= {:image => t[1]}
      end
      
      return h_containers
    end

    def kill_run(run)

      if run.command_json
        h_cmd = JSON.parse(run.command_json)
        h_containers = list_containers(h_cmd['host_name'])
#        host_opt = (h_cmd['host_name'] == 'localhost') ? "localhost" : "-H #{h_cmd['host_name']}"
        ## need to create private/public key when host is not localhost
        if h_containers[h_cmd['container_name']]
          cmd = "ssh #{h_cmd['host_name']} 'docker kill #{h_cmd['container_name']}'"
          if h_cmd['host_name'] == 'localhost' and h_cmd['container_name'] and !h_cmd['container_name'].empty?
            cmd = "docker kill #{h_cmd['container_name']}"
          end
          puts cmd
          `#{cmd}`
        end
      end
    end

    def kill_all_runs(project)
      project.runs.each do |run|
        kill_run(run)
      end
    end
    
#    def kill_run_old(logger, run, h_p)
#      
#      pid = (run) ? run.pid : nil
#      docker_image = h_p[:h_cmd_params]['docker_image']
#      docker_call = (docker_image) ? h_p[:h_env]['docker_images'][docker_image]['call'] : nil
#      ps_core_cmd = "ps -ef | egrep '^rvmuser +#{pid} +' | wc -l"
#      ps_cmd = build_docker_cmd(docker_call, docker_run_name, ps_core_cmd)
#
#      if run
#        #  delayed_job = Delayed::Job.where(:id => job.delayed_job_id).first                                                                                                                   #                                      
#        ### delete the job and delayed job if they are pending                                                                                                                                 #                                      
#        if run.status_id == 1
#          #    delayed_job.destroy if delayed_job                                                                                                                                              #                                      
#          run.destroy
#        else
#          if pid and `#{ps_cmd}`.to_i > 0
#            ## kill main process   
#            kill_pid(nil, pid)
#            run.update(:status_id => 5)
#          end
#        end
#      end
#
#    end


#    def kill_run_inside_docker(logger, run, h_p) ## if the pid corresponds to the job pid inside the docker
#      
#      pid = (run) ? run.pid : nil
#      docker_image = h_p[:h_cmd_params]['docker_image']
#      docker_call = (docker_image) ? h_p[:h_env]['docker_images'][docker_image]['call'] : nil
#      ps_core_cmd = "ps -ef | egrep '^rvmuser +#{pid} +' | wc -l"
#      ps_cmd = build_docker_cmd(docker_call, ps_core_cmd)
#
#      if run
#        #  delayed_job = Delayed::Job.where(:id => job.delayed_job_id).first
#        ### delete the job and delayed job if they are pending                                                                                                                                 #   
#        if run.status_id == 1
#          #    delayed_job.destroy if delayed_job
#          run.destroy
#        else
#          if pid and `#{ps_cmd}`.to_i > 0
#            ## kill main process          
#            #     Process.kill('INT', pid) #Process::kill 0, job.pid           
#            kill_pid(docker_call, pid)
#            ## kill remaining children processes                                                  
##            processes = Sys::ProcTable.ps.select{ |pe| pe.ppid == pid }
#            children_pids = get_children_pids(docker_call, pid)
#            logger.debug("KILL CHILDREN: #{children_pids.to_json}")
#            children_pids.each do |pe|
#              kill_pid(docker_call, pe)
#            end
#            run.update(:status_id => 5)
#         #   delayed_job.destroy if delayed_job
#          end
#        end
#      end
#
#    end
    
    def kill_jobs(logger, project_id, step_id, o =nil)
      jobs = []
#      if step_id < 5
      jobs = Job.where(:project_id => project_id, :step_id => step_id, :status_id => 2).all.to_a
      logger.debug("JOBS_TO_KILL: #{jobs.size}")
      if step_id == 4
        jobs = jobs.select{|j| j.command_line.match(/#{o.dim_reduction.name}/)}
      end
      logger.debug("JOBS_TO_KILL_2: " + jobs.size.to_s)
      
      jobs.each do |job| 
       kill_job(logger, job)
#        if job and `ps -ef | egrep '^rvmuser +#{job.pid} +' | wc -l`.to_i > 0
#          ## kill main process
#          Process.kill('INT', job.pid) #Process::kill 0, job.pid 
#          ## kill children processes
#          processes = Sys::ProcTable.ps.select{ |pe| pe.ppid == job.pid }#          logger.debug("KILL CHILDREN: #{processes}")
#          processes.each do |pe|
#            Process.kill('INT', pe.pid)
#          end
#          job.update(:status_id => 5)
#        end
      end
      #     end
    end

#     job = Basic.run_job(logger, cmd, self, self, 1, output_file, output_json, queue, self.parsing_job_id, self.user)

    def run_job(logger, cmd, project, o, step_id, output_file, output_json, queue, job_id, user)
      
      start_time = Time.now
      
      logger.debug("CMD2: " + cmd)

#      jobs = []
#      if step_id < 5
#        Basic.kill_jobs(logger, project.id, step_id, o)
#      end
      
      #      project_step = ProjectStep.where(:project_id => project.id, :step_id => step_id).first
      ### search potentially running script                                                                                                                    
      file = ''
      if m = cmd.match(/-f ([^ ]+)/)
        file = m[1]
      end
      logger.debug("CMD_ls : " + `ls -alt #{file}`)
      pid = spawn(cmd)
      logger.debug("CMD3: " + cmd)
      logger.debug("CMD_ls2 : " + `ls -alt #{file}`)
      job = Job.find(job_id)

      h_job = {
        :project_id => project.id,
        :step_id => step_id,
        :command_line => cmd,
        :status_id => 2,
        :user_id => (user) ? user.id : 1,
        :speed_id => queue,
        :pid => pid
      }
#      job = Job.new(h_job)
#      job.save
      job.update(h_job)
    #  project.broadcast step_id
#      job_id_fields = [:parsing_job_id, :filtering_job_id, :normalization_job_id]
#      if step_id < 4
#        o.update_attribute(job_id_fields[step_id-1], job.id)
#      else
#        o.update_attribute(:job_id, job.id)
#      end
      #logger.debug("BLABLABLA")

      Process.waitpid(pid)
      
      #      launch_cmd(cmd, self)                                                                                                                                           
      logger.debug "CMD_STATUS: #{$?.stopped?}" 

      if ! $?.stopped?  #(job and ! $?.stopped?) or (results["original_error"] or results["displayed_error"])
      
        results = {}
        if  File.exist?(output_json)
          begin
            results = JSON.parse(File.read(output_json))
          rescue Exception => e
            results['displayed_error']='Bad format'
            File.open(output_json, 'w') do |f|
              f.write(results.to_json)
            end
          end
        end
  
        ### update duration                                                                                                                                                        
        duration = Time.now - start_time
        if File.exist?(output_file) and !results["original_error"] and !results["displayed_error"]
          job && job.update(:status_id => 3, :duration => duration)
        else
          job && job.update(:status_id => 4, :duration => duration)
        end
        
      end
      
#       project.broadcast_new_status
      return job
      
    end

#    def create_job(cmd, project)
#      
    #    end
    
    def launch_cmd(command, obj)
      logger.debug("CMD2: " + command)
      
      pid = spawn(command)
      obj.update_attribute(:pid, pid)
      while 1 do
        alive?(pid)
        sleep 3
      end
    end
    
    #  def alive?(pid)
    #    !!Process.kill(0, pid) rescue false
    #  end
    
    def sum(t)
      sum=0
      t.select{|e| e}.each do |e|
        sum+=e
      end
      return sum
    end
    
    def mean(t)
      sum=0
      t.select{|e| e}.each do |e|
        sum+=e
      end
      return (t.size > 0) ? sum.to_f/t.size : nil
    end
    
    def median(t1)
      t=t1.select{|e| e}.sort
      n=t.size
      if (n >0)
        if (n%2 == 0)
          return mean([t[(n/2)-1], t[n/2]])
        else
          # puts n/2                                                                                                                           
          return t[n/2]
        end
      else
        return nil
      end
    end
    
    def safe_download(url, filepath, max_size: nil)
      require 'open-uri'
      #    Error = Class.new(StandardError)                                                                                                                                                                                    
      
      #    DOWNLOAD_ERRORS = [                                                                                                                                                                                                 
      #                       SocketError,                                                                                                                                                                                     
      #                       OpenURI::HTTPError,                                                                                                                                                                              
      #                       RuntimeError,                                                                                                                                                                                    
      #                       URI::InvalidURIError,                                                                                                                                                                            
      #                       Error,                                                                                                                                                                                           
      #                      ]                                                                                                                                                                                                 
      
      url = URI.encode(URI.decode(url))
      url = URI(url)
      raise Error, "url was invalid" if !url.respond_to?(:open)
      
      options = {}
      options["User-Agent"] = "MyApp/1.2.3"
      options[:read_timeout] = 10000
      options[:content_length_proc] = ->(size) {
        if max_size && size && size > max_size
          raise Error, "file is too big (max is #{max_size})"
        end
      }
      
      downloaded_file = url.open(options)
      
      if downloaded_file.is_a?(StringIO)
        # tempfile = Tempfile.new("open-uri", binmode: true)                                                                                                                                                                
        IO.copy_stream(downloaded_file, filepath)
        # downloaded_file = tempfile                                                                                                                                                                                        
        # OpenURI::Meta.init downloaded_file, stringio                                                                                                                                                                      
      end
      
      #   downloaded_file                                                                                                                                                                                                     
      
      #  rescue *DOWNLOAD_ERRORS => error                                                                                                                                                                                
      #    raise if error.instance_of?(RuntimeError) && error.message !~ /redirection/                                                                                                                                    
      #    raise Error, "download failed (#{url}): #{error.message}"                                                                                                                                                           
    end
    
    
    def std_dev(t)
      t=t.select{|e| e}
      n=t.size
      if (n >0)
        m=mean(t)
        tot=0
        t.map{|e| tot+=(e-m)**2}
        return (tot / n)**0.5
      else
        return nil
      end
    end
    
    def min(t)
      return t.select{|e| e}.sort.first
    end
    
    def max(t)
      return t.select{|e| e}.sort.last
    end
  end
end
