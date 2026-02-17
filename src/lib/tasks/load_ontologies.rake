desc 'Load/update ontology terms from OBO files'
task load_ontologies: :environment do
  puts 'Executing...'

  now = Time.now

  data_dir = Pathname.new(ENV.fetch('USER_DATA_DIR', '/data/asap2_test/users'))
  ontology_dir = data_dir.join('..', 'ontologies')
  FileUtils.mkdir_p(ontology_dir)

  def load_ontology_term(co, h_term)
    return unless h_term['id']

    t = h_term['id'].split(':')
    t = h_term['id'].split('_') if t.size == 1
    original = (t[0] == co.tag)

    if !original && h_term['alt_id']
      replace = nil
      h_term['alt_id'].each do |e|
        t2 = e.split(':')
        if t2[0] == co.tag
          original = true
          replace = e
          break
        end
      end
      if replace
        index = h_term['alt_id'].index(replace)
        h_term['alt_id'][index] = h_term['id']
        h_term['id'] = replace
      end
    end

    if co.tag == 'EFO' && (m = h_term['id'].match(/^efo\:EFO_(.+)/))
      h_term['alt_id'] = [h_term['id']]
      h_term['id'] = "EFO:#{m[1]}"
      original = true
    end

    h_co_term = {
      cell_ontology_id: co.id,
      alt_identifiers: h_term['alt_id']&.join(','),
      identifier: h_term['id'],
      name: h_term['name'],
      description: h_term['def']&.gsub(/^"(.+?)".*/, '\1'),
      comment: h_term['comment']&.gsub(/^"(.+?)".*/, '\1'),
      content_json: h_term.to_json,
      original: original,
      tax_id: h_term['tax_id']
    }

    cot = CellOntologyTerm.where(cell_ontology_id: co.id, identifier: h_term['id']).first
    if !cot
      h_co_term[:latest_version] = co.latest_version
      puts "New #{h_co_term[:identifier]} #{h_co_term[:name]}"
      cot = CellOntologyTerm.new(h_co_term)
      cot.save
    else
      h_existing = {
        cell_ontology_id: cot.cell_ontology_id,
        alt_identifiers: cot.alt_identifiers,
        identifier: cot.identifier,
        name: cot.name,
        description: cot.description,
        comment: cot.comment,
        original: cot.original,
        tax_id: cot.tax_id
      }

      if h_co_term.slice(*h_existing.keys) != h_existing
        puts "Update #{h_co_term[:identifier]}"
        cot.update(h_co_term)
      end
    end
  end

  # Optionally limit to specific ontology tags via environment variable:
  #   rake load_ontologies ONTOLOGIES=EFO,PATO,MONDO
  filter_tags = ENV['ONTOLOGIES']&.split(',')&.map(&:strip)

  CellOntology.where(obsolete: false).order(id: :desc).each do |co|
    next if filter_tags && !filter_tags.include?(co.tag)
    next unless co.file_url.present?

    puts "=> Loading #{co.name} (#{co.tag}) from #{co.file_url}"

    # Download file
    ori_file = ontology_dir.join("#{co.id}.#{co.format}")
    system("wget -q -O #{ori_file} '#{co.file_url}'")

    unless File.exist?(ori_file) && File.size(ori_file) > 0
      puts "  Download failed, skipping."
      next
    end

    obo_file = ori_file
    if co.format == 'owl'
      obo_file = ontology_dir.join("#{co.id}.obo")
      owl2obo_bin = "java -jar #{data_dir.join('..', 'bin', 'owl2obo.jar')}"
      system("#{owl2obo_bin} -i #{ori_file} -o #{obo_file}")
    end

    h_term = {}
    potential_date_fields = %w[date remark data-version]
    single_fields = %w[id name def namespace comment]
    multiple_fields = %w[synonyms alt_id is_a part_of disjoint_from]
    flag_term = 0
    count = 0

    File.open(obo_file) do |f|
      while (l = f.gets)
        l.chomp!
        t = l.split(/\: /)

        if co.tag == 'CVCL' && (m = l.match(/^name:(.+)/))
          t = ['name', m[1]]
        end

        if potential_date_fields.include?(t[0]) && (m = t[1]&.match(/(\d+)[\:\-](\d+)[\:\-](\d+)/))
          if m[3].to_i > 2000
            co.update(latest_version: "#{m[3]}-#{m[2]}-#{m[1]}")
          elsif m[1].to_i > 2000
            co.update(latest_version: "#{m[1]}-#{m[2]}-#{m[3]}")
          end
        elsif l == '' && h_term != {}
          load_ontology_term(co, h_term)
          count += 1
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
            v = m[2].gsub(%r{http://flybase.org/reports/}, '')
            h_term['relationship'][m[1]].push(v)
          elsif ((m = l.match(/^(\w+)\: (.+?) \!/)) || (m = l.match(/^(\w+)\: (.+)/))) && multiple_fields.include?(m[1])
            h_term[m[1]] ||= []
            h_term[m[1]].push(m[2].gsub(/ \!$/, ''))
          elsif (m = l.match(/NCBITaxon:(\d+)/))
            h_term['tax_id'] = m[1]
          end
        end
      end

      load_ontology_term(co, h_term) if h_term['id']
    end

    puts "  Loaded #{count} terms."
  end

  elapsed = Time.now - now
  puts "Done in #{elapsed.round(1)}s."
end
