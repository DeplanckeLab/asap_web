class CellOntologiesController < ApplicationController
  before_action :authenticate_user!
  skip_before_action :authenticate_user!, only: [:index, :show], raise: false
  before_action :authorize_admin, except: [:index, :show]
  before_action :ensure_synced_reference_data_writable!, except: [:index, :show]
  before_action :set_cell_ontology, only: [:show, :edit, :update, :destroy]

  def index
    @cell_ontologies = CellOntology.order(Arel.sql("LOWER(name) ASC"))
    @organisms_by_tax_id = fetch_organisms_by_tax_id(@cell_ontologies)
    @term_counts = term_counts_for(@cell_ontologies)
  end

  def show
    @total_terms = @cell_ontology.cell_ontology_terms.count
    @original_terms = @cell_ontology.cell_ontology_terms.original.count
    @sample_terms = @cell_ontology.cell_ontology_terms
                                 .original
                                 .order(Arel.sql("LOWER(name) ASC"))
                                 .limit(100)
    @organism_names = organism_names_for(@cell_ontology)
  end

  def new
    @cell_ontology = CellOntology.new
  end

  def create
    @cell_ontology = CellOntology.new(cell_ontology_params)

    if @cell_ontology.save
      redirect_to cell_ontologies_path, notice: "Cell ontology created."
    else
      flash.now[:alert] = "Unable to create cell ontology."
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @cell_ontology.update(cell_ontology_params)
      redirect_to cell_ontologies_path, notice: "Cell ontology updated."
    else
      flash.now[:alert] = "Unable to update cell ontology."
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @cell_ontology.destroy
    redirect_to cell_ontologies_path, notice: "Cell ontology deleted."
  end

  private

  def set_cell_ontology
    @cell_ontology = CellOntology.find(params[:id])
  end

  def cell_ontology_params
    params.require(:cell_ontology).permit(:name, :tag, :format, :latest_version, :url, :file_url, :url_mask, :tax_ids, :obsolete)
  end

  def fetch_organisms_by_tax_id(cell_ontologies)
    tax_ids = cell_ontologies.flat_map(&:tax_id_list).uniq
    return {} if tax_ids.empty?

    Organism.where(tax_id: tax_ids).index_by(&:tax_id)
  end

  def term_counts_for(cell_ontologies)
    ids = cell_ontologies.map(&:id)
    return { total: {}, original: {} } if ids.empty?

    totals = CellOntologyTerm.where(cell_ontology_id: ids).group(:cell_ontology_id).count
    originals = CellOntologyTerm.where(cell_ontology_id: ids, original: true).group(:cell_ontology_id).count

    { total: totals, original: originals }
  end

  def organism_names_for(cell_ontology)
    return ["All organisms"] if cell_ontology.applies_to_all_organisms?

    tax_ids = cell_ontology.tax_id_list
    return ["No match"] if tax_ids.empty?

    names_by_tax_id = Organism.where(tax_id: tax_ids).index_by(&:tax_id)
    names = tax_ids.map { |tax_id| names_by_tax_id[tax_id]&.name || "Tax ID #{tax_id}" }
    names.presence || ["No match"]
  end
end

