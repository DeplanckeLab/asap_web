# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'

# UI imports pause for the project form when the catalog entry's species is missing or not in ASAP, or the
# downloaded file is a text matrix whose parsing parameters must be checked.
class ExternalCatalogOrganismChoiceTest < ActiveSupport::TestCase
  setup do
    @version = Version.activated.where('id > 3').order(id: :desc).first || Version.order(id: :desc).first
    skip 'No Version available for importer tests' unless @version
    @organism = Organism.order(:id).first
    skip 'No Organism available for importer tests' unless @organism

    @user = register_for_test_cleanup(
      User.create!(email: "orgch_#{SecureRandom.hex(4)}@example.com", password: 'password123')
    )
    @version_organisms = [{ 'id' => @organism.id, 'tax_id' => 123_456, 'short_name' => 'beast' }]
  end

  def importer(ask:)
    ExternalCatalog::ProjectImporter.new(
      user: @user, version: @version, skip_archive: true, skip_publish: true, ask_user_choice: ask
    )
  end

  def entry(tax_id:, organism_label: nil)
    ExternalCatalog::Entry.new(
      source: 'cellxgene',
      external_id: "orgch-#{SecureRandom.hex(4)}",
      title: 'Organism choice',
      url: 'https://example.com/orgch.h5ad',
      tax_id: tax_id,
      organism_label: organism_label,
      project_type_tag: 'sc',
      format_kind: :h5ad
    )
  end

  def resolve(imp, entry)
    imp.stub(:version_organisms, @version_organisms) { imp.send(:resolve_organism!, entry) }
  end

  test 'a tax_id not in ASAP asks for the species in UI imports and is skipped in batch imports' do
    error = assert_raises(ExternalCatalog::ProjectImporter::NeedsUserChoice) do
      resolve(importer(ask: true), entry(tax_id: 999_999_999, organism_label: 'Unknown beast'))
    end
    assert_equal 999_999_999, error.tax_id
    assert_equal 'Unknown beast', error.organism_label

    assert_raises(ExternalCatalog::ProjectImporter::SkipEntry) do
      resolve(importer(ask: false), entry(tax_id: 999_999_999))
    end
  end

  test 'a missing tax_id asks for the species' do
    error = assert_raises(ExternalCatalog::ProjectImporter::NeedsUserChoice) do
      resolve(importer(ask: true), entry(tax_id: nil))
    end
    assert_nil error.tax_id
  end

  test 'a known tax_id still resolves' do
    assert_equal @organism, resolve(importer(ask: true), entry(tax_id: 123_456))
  end

  def h5ad_entry
    ExternalCatalog::Entry.new(
      source: 'cellxgene',
      external_id: "orgh5-#{SecureRandom.hex(4)}",
      title: 'Organism from uns',
      url: 'https://example.com/orgh5.h5ad',
      tax_id: 999_999_999,
      organism_label: 'Unknown beast',
      project_type_tag: 'sc',
      format_kind: :h5ad
    )
  end

  test 'the species in /uns is suggested: ontology term first, then the name' do
    imp = importer(ask: true)
    fu = Fu.new(id: 1)
    imp.stub(:version_organisms, [@version_organisms.first.merge('name' => 'Mythical beast')]) do
      imp.stub(:read_h5ad_uns_organism, { 'organism_ontology_term_id' => 'NCBITaxon:123456', 'organism' => 'x' }) do
        assert_equal [@organism.id, '/uns/organism_ontology_term_id = NCBITaxon:123456'],
                     imp.send(:suggest_organism_from_h5ad, fu)
      end
      imp.stub(:read_h5ad_uns_organism, { 'organism_ontology_term_id' => 'NCBITaxon:1', 'organism' => 'mythical Beast' }) do
        assert_equal [@organism.id, '/uns/organism = mythical Beast'], imp.send(:suggest_organism_from_h5ad, fu)
      end
      imp.stub(:read_h5ad_uns_organism, { 'organism_ontology_term_id' => 'NCBITaxon:1', 'organism' => nil }) do
        assert_equal [nil, nil], imp.send(:suggest_organism_from_h5ad, fu)
      end
      imp.stub(:read_h5ad_uns_organism, ->(_fu) { raise 'h5py failed' }) do
        assert_equal [nil, nil], imp.send(:suggest_organism_from_h5ad, fu)
      end
    end
  end

  test 'an H5AD is downloaded before asking, with the species of its /uns as default' do
    imp = importer(ask: true)
    fu = Fu.new(id: 42)
    downloaded_with = :not_called
    error = nil
    imp.stub(:version_organisms, @version_organisms) do
      imp.stub(:download_and_preparse!, ->(_entry, organism) { downloaded_with = organism; fu }) do
        imp.stub(:suggest_organism_from_h5ad, [@organism.id, '/uns/organism = beast']) do
          error = assert_raises(ExternalCatalog::ProjectImporter::NeedsUserChoice) { imp.import_one(h5ad_entry) }
        end
      end
    end
    assert_nil downloaded_with
    assert_same fu, error.fu
    assert_equal @organism.id, error.suggested_organism_id
    assert_equal '/uns/organism = beast', error.suggestion
    assert_equal 999_999_999, error.tax_id
    assert_equal :organism, error.reason
  end

  test 'other formats are downloaded too before asking, with the species of their gene ids as default' do
    imp = importer(ask: true)
    other = h5ad_entry.tap { |e| e.format_kind = :loom }
    fu = Fu.new(id: 43)
    downloaded_with = :not_called
    error = nil
    output = { 'detected_format' => 'LOOM', 'list_groups' => [{ 'genes' => %w[ENSMUSG00000000001 ENSMUSG00000000003 Xkr4] }] }
    imp.stub(:version_organisms, [{ 'id' => @organism.id, 'tax_id' => 10_090, 'short_name' => 'mouse' }]) do
      imp.stub(:download_and_preparse!, ->(_entry, organism) { downloaded_with = organism; fu }) do
        imp.stub(:suggest_organism_from_h5ad, ->(_fu) { flunk 'not an H5AD' }) do
          imp.stub(:preparsing_output, output) do
            error = assert_raises(ExternalCatalog::ProjectImporter::NeedsUserChoice) { imp.import_one(other) }
          end
        end
      end
    end
    assert_nil downloaded_with
    assert_same fu, error.fu
    assert_equal @organism.id, error.suggested_organism_id
    assert_equal 'gene ids such as ENSMUSG00000000001', error.suggestion
  end

  test 'gene symbols alone suggest no species' do
    imp = importer(ask: true)
    imp.stub(:preparsing_output, { 'list_groups' => [{ 'genes' => %w[Xkr4 Actb ENSG00000000003] }] }) do
      assert_equal [nil, nil], imp.send(:suggest_organism_from_gene_ids, Fu.new(id: 44))
    end
  end

  test 'a downloaded text matrix pauses for its parsing parameters, even with a known species' do
    imp = importer(ask: true)
    text = h5ad_entry.tap do |e|
      e.source = 'broad_scp'
      e.format_kind = :counts_table
      e.filename = 'Neuron_Data.txt'
    end
    fu = Fu.new(id: 45)
    text.tax_id = 123_456
    error = nil
    imp.stub(:version_organisms, @version_organisms) do
      imp.stub(:download_and_preparse!, fu) do
        imp.stub(:preparsing_output, { 'detected_format' => 'RAW_TEXT', 'list_groups' => [{ 'genes' => %w[Actb] }] }) do
          error = assert_raises(ExternalCatalog::ProjectImporter::NeedsUserChoice) { imp.import_one(text) }
        end
      end
    end
    assert_same fu, error.fu
    assert_equal :text, error.reason
    assert_equal @organism.id, error.organism_id
  end

  test 'text tables the importer rewrites itself keep their parsing parameters' do
    imp = importer(ask: true)
    geo = h5ad_entry.tap do |e|
      e.source = 'geo'
      e.format_kind = :counts_table
    end
    imp.stub(:preparsing_output, { 'detected_format' => 'RAW_TEXT' }) do
      refute imp.send(:user_text_matrix?, Fu.new(id: 46), geo)
    end
  end

  test 'the job keeps the download and the suggestion while waiting for the project form' do
    candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: "orgjob-#{SecureRandom.hex(4)}",
        provider_tag: 'CELLxGENE',
        title: 'Organism choice job (H5AD)',
        url: 'https://example.com/orgjob.h5ad',
        import_status: 'importing',
        import_user_id: @user.id,
        tax_id: 999_999_999
      )
    )
    fu = register_for_test_cleanup(
      Fu.create!(user_id: @user.id, upload_file_name: 'input_file.h5ad', upload_file_size: 0, status: 'preparsed')
    )
    organism_id = @organism.id
    fake = Object.new
    fake.define_singleton_method(:import_one) do |*_args, **_kwargs|
      raise ExternalCatalog::ProjectImporter::NeedsUserChoice.new(
        'No ASAP organism', reason: :organism, tax_id: 999_999_999, organism_label: nil,
        fu: fu, suggested_organism_id: organism_id, suggestion: '/uns/organism = beast'
      )
    end

    ExternalCatalog::ProjectImporter.stub(:new, fake) do
      ExternalCatalogImportCandidateJob.perform_now(candidate.id, @user.id, version_id: @version.id)
    end

    candidate.reload
    assert candidate.awaiting_form?
    assert_equal 'organism', candidate.import_resume['reason']
    assert_equal fu.id, candidate.import_resume['fu_id']
    assert_equal organism_id, candidate.import_resume['suggested_organism_id']
    assert_equal '/uns/organism = beast', candidate.import_resume['suggestion']
    assert Fu.exists?(fu.id)

    assert candidate.cancel_matrix_choice!
    refute Fu.exists?(fu.id)
  ensure
    ExternalCatalog::ImportProgress.clear(candidate.id) if candidate
  end

  test 'the job finishes a project created in the project form instead of importing again' do
    candidate = register_for_test_cleanup(
      ExternalCatalogCandidate.create!(
        source: 'cellxgene',
        external_id: "orgform-#{SecureRandom.hex(4)}",
        provider_tag: 'CELLxGENE',
        title: 'Form import job',
        url: 'https://example.com/orgform.h5ad',
        import_status: 'importing',
        import_user_id: @user.id,
        tax_id: 9606
      )
    )
    project = create_test_project!(user_id: @user.id, public: false)
    calls = []
    fake = Object.new
    fake.define_singleton_method(:import_one) { |*_args, **_kwargs| flunk 'downloaded again' }
    fake.define_singleton_method(:complete_form_import) do |_entry, form_project, on_project_ready: nil|
      calls << form_project.id
      on_project_ready&.call(form_project, :created)
      form_project
    end
    fake.define_singleton_method(:last_import_outcome) { :created }

    ExternalCatalog::ProjectImporter.stub(:new, fake) do
      ExternalCatalog::ImportSuccessRegistry.stub(:record_import_attempt!, nil) do
        ExternalCatalogImportCandidateJob.perform_now(candidate.id, @user.id, version_id: @version.id, project_id: project.id)
      end
    end

    assert_equal [project.id], calls
    candidate.reload
    assert_equal 'idle', candidate.import_status
    assert_equal project.id, candidate.import_project_id
  ensure
    ExternalCatalog::ImportProgress.clear(candidate.id) if candidate
  end
end
