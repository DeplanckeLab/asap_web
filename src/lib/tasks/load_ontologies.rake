desc '####################### load ontology terms'
task load_ontologies: :environment do
  require 'fileutils'
  require 'shellwords'

  class OntologyTermLoader
    INSERT_BATCH_SIZE = 1_000
    COMPARE_ATTRS = %i[
      cell_ontology_id alt_identifiers identifier name description comment original obsolete tax_id
    ].freeze

    def self.verbose?
      ENV['VERBOSE'].present?
    end

    def initialize(cell_ontology)
      @co = cell_ontology
      @existing = CellOntologyTerm.where(cell_ontology_id: @co.id).index_by(&:identifier)
      @pending_inserts = []
      @stats = { inserted: 0, updated: 0, unchanged: 0 }
    end

    def process_term(h_term)
      return if h_term['id'].blank?

      normalize_term!(h_term)
      attrs = build_attrs(h_term)
      identifier = attrs[:identifier]
      cot = @existing[identifier]

      if cot.nil?
        queue_insert(attrs)
        return
      end

      if term_unchanged?(cot, attrs)
        @stats[:unchanged] += 1
        return
      end

      cot.update!(attrs)
      @stats[:updated] += 1
    end

    def finish!
      flush_inserts!
      puts "#{@co.tag}: inserted=#{@stats[:inserted]} updated=#{@stats[:updated]} unchanged=#{@stats[:unchanged]}"
    end

    private

    def normalize_term!(h_term)
      t = h_term['id'].split(':')
      t = h_term['id'].split('_') if t.size == 1
      original = t[0] == @co.tag

      if !original && h_term['alt_id']
        replace = nil
        Array(h_term['alt_id']).each do |alt_id|
          alt_id.split(':')
          if t[0] == @co.tag
            original = true
            replace = alt_id
            break
          end
        end
        if replace
          h_term['alt_id'] = Array(h_term['alt_id'])
          index = h_term['alt_id'].index(replace)
          h_term['alt_id'][index] = h_term['id']
          h_term['id'] = replace
          log_verbose("Replaced alt_id with #{replace} for #{@co.tag}")
        end
      end

      if @co.tag == 'EFO' && (m = h_term['id'].match(/^efo:EFO_(.+)/i))
        h_term['alt_id'] = [h_term['id']]
        h_term['id'] = "EFO:#{m[1]}"
        original = true
      end

      h_term['original'] = original
    end

    def build_attrs(h_term)
      {
        cell_ontology_id: @co.id,
        alt_identifiers: h_term['alt_id'] ? Array(h_term['alt_id']).join(',') : nil,
        identifier: h_term['id'],
        name: h_term['name'],
        description: extract_quoted_field(h_term['def']),
        comment: extract_quoted_field(h_term['comment']),
        content_json: h_term.to_json,
        original: h_term['original'],
        obsolete: h_term['is_obsolete'].to_s.strip.downcase == 'true',
        tax_id: h_term['tax_id']
      }
    end

    def extract_quoted_field(value)
      return nil if value.blank?

      value.gsub(/^"(.+?)".+/m, '\1')
    end

    def term_unchanged?(cot, attrs)
      COMPARE_ATTRS.all? do |key|
        cot.public_send(key) == attrs[key]
      end
    end

    def queue_insert(attrs)
      @pending_inserts << attrs.merge(latest_version: @co.latest_version)
      flush_inserts! if @pending_inserts.size >= INSERT_BATCH_SIZE
    end

    def flush_inserts!
      return if @pending_inserts.empty?

      now = Time.current
      rows = @pending_inserts.map { |attrs| attrs.merge(created_at: now, updated_at: now) }
      CellOntologyTerm.insert_all(rows)
      @stats[:inserted] += rows.size
      @pending_inserts.clear
    end

    def log_verbose(message)
      puts message if self.class.verbose?
    end
  end

  puts 'Executing load_ontologies...'

  data_dir_value = if defined?(APP_CONFIG) && APP_CONFIG.respond_to?(:[])
                     APP_CONFIG[:data_dir]
                   end
  data_dir_value = ENV['DATA_DIR'] if data_dir_value.blank?
  data_dir_value = '/data/asap/' if data_dir_value.blank?
  data_dir = Pathname.new(data_dir_value)
  ontology_dir = data_dir + 'ontologies'
  FileUtils.mkdir_p(ontology_dir)
  owl2obo_bin = "java -jar #{data_dir + 'bin' + 'owl2obo.jar'}"

  def fetch_ontology_file(file_path, url)
    FileUtils.mkdir_p(File.dirname(file_path.to_s))
    escaped_file = Shellwords.escape(file_path.to_s)
    escaped_url = Shellwords.escape(url.to_s)
    use_conditional = File.exist?(file_path)

    cmd = if use_conditional
            "curl -L -sS -z #{escaped_file} -o #{escaped_file} -w '%{http_code}' #{escaped_url}"
          else
            "curl -L -sS -o #{escaped_file} -w '%{http_code}' #{escaped_url}"
          end

    http_code = `#{cmd}`.to_s.strip
    raise "Unable to download ontology from #{url} (HTTP #{http_code})" unless %w[200 304].include?(http_code)

    http_code == '200'
  end

  output_json = Pathname.new(data_dir_value) + 'tmp' + 'tool_versions.json'
  FileUtils.mkdir_p(output_json.dirname)

  h_tool_versions = Basic.safe_parse_json(output_json, {})
  h_new_tool_versions = {}
  h_tool_versions.each_key do |k|
    h_new_tool_versions[k] = h_tool_versions[k]
  end

  CellOntology.where(obsolete: false).order(id: :desc).then { |scope|
    ENV['ONTOLOGY_TAG'].present? ? scope.where(tag: ENV['ONTOLOGY_TAG']) : scope
  }.find_each do |co|
    if co.file_url.blank?
      puts "Skipping #{co.tag} (id=#{co.id}): file_url is not set"
      next
    end
    if co.format.blank?
      puts "Skipping #{co.tag} (id=#{co.id}): format is not set"
      next
    end

    ori_file = ontology_dir + "#{co.id}.#{co.format}"
    source_changed = fetch_ontology_file(ori_file, co.file_url)

    obo_file = ori_file
    if co.format == 'owl'
      obo_file = ontology_dir + "#{co.id}.obo"
      if source_changed || !File.exist?(obo_file)
        cmd = "#{owl2obo_bin} -i #{ori_file} -o #{obo_file}"
        `#{cmd}`
      end
    end

    terms_already_loaded = CellOntologyTerm.where(cell_ontology_id: co.id).exists?
    if !source_changed && File.exist?(obo_file) && terms_already_loaded
      puts "#{co.tag}: no source changes; skipped"
      next
    end

    loader = OntologyTermLoader.new(co)
    h_term = {}
    potential_date_fields = %w[date remark data-version]
    single_fields = %w[id name def namespace comment is_obsolete]
    multiple_fields = %w[synonyms alt_id is_a part_of disjoint_from xref equivalent_to consider replaced_by]
    flag_term = 0

    File.open(obo_file) do |f|
      while (l = f.gets)
        l.chomp!
        t = l.split(/\: /)
        if co.tag == 'CVCL' && (m = l.match(/^name:(.+)/))
          t = ['name', m[1]]
        end

        if potential_date_fields.include?(t[0]) && !h_new_tool_versions[co.tag] && (m = t[1].match(/(\d+)[\:\-](\d+)[\:\-](\d+)/))
          if m[3].to_i > 2000
            h_new_tool_versions[co.tag] = "#{m[3]}-#{m[2]}-#{m[1]}"
          elsif m[1].to_i > 2000
            h_new_tool_versions[co.tag] = "#{m[1]}-#{m[2]}-#{m[3]}"
          elsif OntologyTermLoader.verbose?
            puts "ERROR! #{t[1]} is not recognized as a date"
          end
          co.update!(latest_version: h_new_tool_versions[co.tag]) if h_new_tool_versions[co.tag]
        elsif t[0] == 'data-version' && (m = t[1].match(/(\d+)-(\d+)-(\d+)/)) && m[1].to_i > 2000
          h_tool_versions[co.tag] = "#{m[1]}-#{m[2]}-#{m[3]}"
        elsif l == '' && h_term != {}
          loader.process_term(h_term)
          h_term = {}
          flag_term = 0
        elsif l == '[Term]'
          flag_term = 1
        elsif flag_term == 1
          if single_fields.include?(t[0])
            h_term[t[0]] = (1..t.size - 1).map { |i| t[i] }.join(': ')
          elsif (m = l.match(/^relationship: (.+?) (.+?) \!/))
            h_term['relationship'] ||= {}
            h_term['relationship'][m[1]] ||= []
            v = m[2]
            v.gsub!(%r{http://flybase.org/reports/}, '')
            h_term['relationship'][m[1]].push(v)
          elsif ((m = l.match(/^(\w+): (.+?) \!/)) || (m = l.match(/^(\w+): (.+)/))) && multiple_fields.include?(m[1])
            h_term[m[1]] ||= []
            h_term[m[1]].push(m[2].gsub(/ \!$/, ''))
          elsif (m = l.match(/NCBITaxon:(\d+)/))
            h_term['tax_id'] = m[1]
          end
        end
      end

      loader.process_term(h_term)
    end

    loader.finish!
  end

  h_new_tool_versions.each_key do |k|
    h_tool_versions[k] = h_new_tool_versions[k]
  end

  File.open(output_json, 'w') { |f| f.write(h_tool_versions.to_json) }
  puts 'load_ontologies finished'
end
