module Fetch
  class << self
    # Load articles from PMIDs and update exp_entry with DOI if found
    def load_articles(pmids, exp_entry = nil)
      return if pmids.blank?

      ActiveRecord::Base.transaction do
        pmids.to_s.split(";").each do |pmid|
          pmid = pmid.strip
          next if pmid.blank?

          h_article = fetch_pubmed(pmid)
          next unless h_article

          article = Article.find_by(pmid: pmid)
          if article
            article.update(h_article)
          else
            article = Article.create(h_article)
          end

          # Update exp_entry DOI if we found one and exp_entry is provided
          if exp_entry && h_article[:doi].present? && exp_entry.doi.blank?
            exp_entry.update(doi: h_article[:doi])
          end
        end
      end
    end

    # Fetch article data from PubMed including DOI
    def fetch_pubmed(pmid)
      return nil if pmid.blank?

      require 'nokogiri'
      require 'open-uri'

      begin
        url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&id=#{pmid}&retmode=xml"
        doc = Nokogiri::XML(URI.open(url))
        p_article = doc.at("PubmedArticle")

        return nil unless p_article

        citation = p_article.at("MedlineCitation")
        article = citation.at("Article")
        results = { pmid: pmid }

        # Get journal info
        journal_node = article.at("Journal")
        if journal_node
          journal_title = journal_node.at("Title")&.text
          if journal_title.present?
            journal = Journal.find_or_create_by(name: journal_title)
            results[:journal_id] = journal.id
          end

          journal_issue = journal_node.at("JournalIssue")
          if journal_issue
            results[:volume] = journal_issue.at("Volume")&.text
            results[:issue] = journal_issue.at("Issue")&.text
            pubdate = journal_issue.at("PubDate")
            if pubdate
              results[:year] = pubdate.at("Year")&.text || pubdate.at("MedlineDate")&.text&.split(" ")&.first
            end
          end
        end

        # Get title
        results[:title] = article.at("ArticleTitle")&.text

        # Get authors
        author_list = article.at("AuthorList")
        if author_list
          authors = author_list.search("Author")
          all_authors = authors.map do |a|
            lastname = a.at("LastName")&.text
            initials = a.at("Initials")&.text
            [lastname, initials].compact.join(" ")
          end.compact
          results[:authors] = all_authors.join("; ")
        end

        # Get abstract
        abstract = article.at("Abstract")
        results[:abstract] = abstract.at("AbstractText")&.text if abstract

        # Get DOI from ArticleIdList
        pubmed_data = p_article.at("PubmedData")
        if pubmed_data
          article_id_list = pubmed_data.at("ArticleIdList")
          if article_id_list
            doi_node = article_id_list.search("ArticleId").find { |n| n['IdType'] == 'doi' }
            results[:doi] = doi_node&.text
          end
        end

        results
      rescue StandardError => e
        Rails.logger.error("Failed to fetch PubMed data for PMID #{pmid}: #{e.message}")
        nil
      end
    end

    # Fetch DOI info from CrossRef
    def doi_info(doi)
      return {} if doi.blank?

      require 'open-uri'
      require 'json'

      begin
        url = "https://api.crossref.org/works/#{URI.encode_www_form_component(doi)}"
        data_json = URI.open(url).read
        h_json = JSON.parse(data_json)
        m = h_json["message"]

        return {} unless m

        # Get journal
        j_name = m.dig('container-title', 0) || m.dig('institution', 0, 'name') || m.dig('institution', 'name')
        journal = j_name.present? ? Journal.find_or_create_by(name: j_name) : nil

        # Get title
        title = m.dig('title', 0) || ''

        # Get authors
        authors = (m['author'] || []).map do |a|
          given = a['given'] || ''
          family = a['family'] || ''
          initials = given.gsub(/[a-z]/, '').gsub(/\./, '')
          { 'initials' => initials, 'lname' => family }
        end.compact

        fa = authors.first
        author_str = fa ? "#{fa['initials']} #{fa['lname']}#{authors.size > 1 ? ' et al.' : ''}" : nil

        # Get year
        year = nil
        if m['published-print']
          year = m.dig('published-print', 'date-parts', 0, 0)
        elsif m['published-online']
          year = m.dig('published-online', 'date-parts', 0, 0)
        end

        {
          doi: doi,
          title: title,
          authors: author_str,
          authors_json: authors.to_json,
          first_author: fa&.dig('lname'),
          journal_id: journal&.id,
          year: year
        }
      rescue StandardError => e
        Rails.logger.error("Failed to fetch DOI info for #{doi}: #{e.message}")
        {}
      end
    end

    # Update exp_entries with DOI from their PMID
    def update_exp_entry_dois(project = nil)
      scope = project ? project.exp_entries : ExpEntry.all
      
      # Find exp_entries that have PMID but no DOI
      entries_to_update = scope.where.not(pmid: [nil, '']).where(doi: [nil, ''])
      
      count = 0
      entries_to_update.find_each do |exp_entry|
        exp_entry.pmid.to_s.split(";").each do |pmid|
          pmid = pmid.strip
          next if pmid.blank?

          h_article = fetch_pubmed(pmid)
          if h_article && h_article[:doi].present?
            exp_entry.update(doi: h_article[:doi])
            count += 1
            break
          end
        end
      end

      count
    end

    # Fetch ArrayExpress metadata and update exp_entry
    def fetch_array_express(array_express_id)
      require 'open-uri'
      require 'fileutils'

      base_url = "https://www.ebi.ac.uk/arrayexpress/files/#{array_express_id}/#{array_express_id}"
      
      # Download IDF file
      url = "#{base_url}.idf.txt"
      
      begin
        content = URI.open(url).read
      rescue StandardError => e
        Rails.logger.error("Failed to fetch ArrayExpress IDF for #{array_express_id}: #{e.message}")
        return nil
      end

      fields = ["Investigation Title", "Person Last Name", "Person First Name", "Person Mid Initials", 
                "Person Email", "PubMed ID", "Experiment Description", "Public Release Date", 
                "Comment [SecondaryAccession]"]
      h_fields = {}
      fields.each { |field| h_fields[field] = [] }

      content.split("\n").each do |line|
        line.chomp!
        t = line.split(/\t/)
        if fields.include?(t[0])
          (1...t.size).each do |i|
            h_fields[t[0]].push(t[i]) if t[i].present?
          end
        end
      end

      other_identifiers = {
        2 => h_fields["Comment [SecondaryAccession]"].compact
      }

      contributors = (0...h_fields["Person Last Name"].size).map do |i|
        [h_fields["Person Last Name"][i], h_fields["Person Mid Initials"][i], h_fields["Person First Name"][i]].compact.join(",")
      end.join(";")

      submitted_at = h_fields["Public Release Date"].compact.uniq.map { |e| Time.new(e) rescue nil }.compact.min

      h_exp_entry = {
        identifier: array_express_id,
        identifier_type_id: 6, # ArrayExpress type
        contributors: contributors,
        contact_emails: h_fields["Person Email"].join(";"),
        title: h_fields["Investigation Title"].join(" "),
        description: h_fields["Experiment Description"].join(" "),
        identifiers_json: other_identifiers.to_json,
        pmid: h_fields["PubMed ID"].compact.join(";"),
        submitted_at: submitted_at
      }

      exp_entry = ExpEntry.find_or_initialize_by(identifier: array_express_id)
      exp_entry.assign_attributes(h_exp_entry)
      exp_entry.save!

      # Load articles from PMID and update exp_entry DOI
      load_articles(exp_entry.pmid, exp_entry) if exp_entry.pmid.present?

      exp_entry
    end

    # Add/update experimental codes (accession numbers) for a project
    # This is the main entry point for associating exp_entries with projects
    # h should contain:
    #   :project => Project instance
    #   :geo_codes => comma/semicolon separated GEO codes
    #   :array_express_codes => comma/semicolon separated ArrayExpress codes
    #   :ega_codes => comma/semicolon separated EGA codes
    def add_upd_exp_codes(h)
      project = h[:project]
      return unless project

      h_existing_exp_codes = {}
      project.exp_entries.each do |exp_entry|
        h_existing_exp_codes[exp_entry.identifier_type_id] ||= {}
        h_existing_exp_codes[exp_entry.identifier_type_id][exp_entry.identifier] = exp_entry
      end

      # Map code types to identifier_type_ids
      h_code_types = { geo_codes: 5, array_express_codes: 6, ega_codes: 10 }

      h_code_types.each do |code_type, type_id|
        codes_str = h[code_type].to_s.strip
        next if codes_str.blank?

        h_codes = {}
        codes_str.split(/[\s,;]+/).each do |code|
          code = code.strip
          next if code.blank?

          h_codes[code] = 1

          # Check if this exp_entry is already associated
          if !h_existing_exp_codes[type_id] || !h_existing_exp_codes[type_id][code]
            # Fetch the exp_entry data
            if code_type == :geo_codes
              fetch_gse(code)
            elsif code_type == :array_express_codes
              fetch_array_express(code)
            end

            # Associate with project
            exp_entry = ExpEntry.find_by(identifier: code, identifier_type_id: type_id)
            if exp_entry && !project.exp_entries.include?(exp_entry)
              project.exp_entries << exp_entry
            end
          end
        end

        # Remove exp_entries that are no longer in the codes list
        if h_existing_exp_codes[type_id]
          h_existing_exp_codes[type_id].each do |code, exp_entry|
            unless h_codes[code]
              project.exp_entries.delete(exp_entry)
            end
          end
        end
      end
    end

    # Fetch GEO Series metadata
    def fetch_gse(gse_code)
      require 'open-uri'

      h_fields = {
        'Series_pubmed_id' => :pmid,
        'Series_summary' => :description,
        'Series_contributor' => :contributors,
        'Series_contact_email' => :contact_emails,
        'Series_submission_date' => :submitted_at,
        'Series_title' => :title
      }

      begin
        # Try to fetch the series matrix file
        url = "https://ftp.ncbi.nlm.nih.gov/geo/series/#{gse_code[0..-4]}nnn/#{gse_code}/matrix/#{gse_code}_series_matrix.txt.gz"
        
        require 'zlib'
        content = Zlib::GzipReader.new(URI.open(url)).read
      rescue StandardError => e
        Rails.logger.error("Failed to fetch GEO data for #{gse_code}: #{e.message}")
        return nil
      end

      h_exp_entry = { identifier: gse_code, identifier_type_id: 5 }
      h_identifiers = {}

      content.split("\n").each do |line|
        next unless line.start_with?('!')

        if m = line.match(/^\!(.+?)_(.+?)\t(.+?)$/)
          field_key = "#{m[1]}_#{m[2]}"
          values = m[3].split(/\t/).map { |e| e.gsub(/^"|"$/, '') }

          if mapped_field = h_fields[field_key]
            h_exp_entry[mapped_field] ||= []
            h_exp_entry[mapped_field].concat(values)
          end

          # Extract SRA and BioProject identifiers
          if m2 = line.match(/\!Series_relation\t"SRA: https.+?(SRP\d+?)"/)
            h_identifiers[2] ||= []
            h_identifiers[2] << m2[1]
          elsif m2 = line.match(/\!Series_relation\t"BioProject: https.+?(PRJNA\d+?)"/)
            h_identifiers[4] ||= []
            h_identifiers[4] << m2[1]
          end
        end
      end

      # Flatten and join array values
      h_exp_entry.each do |k, v|
        next unless v.is_a?(Array)
        if k == :submitted_at
          h_exp_entry[k] = v.flatten.uniq.map { |e| Time.new(e) rescue nil }.compact.min
        else
          h_exp_entry[k] = v.flatten.uniq.join("; ")
        end
      end

      h_exp_entry[:identifiers_json] = h_identifiers.to_json

      exp_entry = ExpEntry.find_or_initialize_by(identifier: gse_code)
      exp_entry.assign_attributes(h_exp_entry)
      exp_entry.save!

      # Load articles from PMID and update exp_entry DOI
      load_articles(exp_entry.pmid, exp_entry) if exp_entry.pmid.present?

      exp_entry
    end

    # Propagate project DOI to its exp_entries (when they don't have their own DOI)
    def propagate_project_doi(project)
      return 0 if project.doi.blank?

      # Ensure the article exists in the database
      article = Article.find_by(doi: project.doi)
      unless article
        h_article = doi_info(project.doi)
        if h_article.present?
          article = Article.create(h_article)
        end
      end

      count = 0
      project.exp_entries.where(doi: [nil, '']).each do |exp_entry|
        exp_entry.update(doi: project.doi)
        count += 1
      end

      count
    end
  end
end

