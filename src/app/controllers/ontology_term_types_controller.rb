class OntologyTermTypesController < ApplicationController
  before_action :authenticate_user!, except: :index
  before_action :authorize_admin, except: :index
  before_action :set_ontology_term_type, only: [:edit, :update, :destroy]

  def index
    @ontology_term_types = OntologyTermType.order(Arel.sql("COALESCE(rank, 999999), LOWER(name)"))
    @cell_ontologies = cell_ontologies_for(@ontology_term_types)
    @terms_by_id = terms_for(@ontology_term_types)
  end

  def new
    @ontology_term_type = OntologyTermType.new
  end

  def create
    @ontology_term_type = OntologyTermType.new(ontology_term_type_params)

    if @ontology_term_type.save
      redirect_to ontology_term_types_path, notice: "Ontology term type created."
    else
      flash.now[:alert] = "Unable to create ontology term type."
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @ontology_term_type.update(ontology_term_type_params)
      redirect_to ontology_term_types_path, notice: "Ontology term type updated."
    else
      flash.now[:alert] = "Unable to update ontology term type."
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @ontology_term_type.destroy
    redirect_to ontology_term_types_path, notice: "Ontology term type deleted."
  end

  private

  def set_ontology_term_type
    @ontology_term_type = OntologyTermType.find(params[:id])
  end

  def ontology_term_type_params
    params.require(:ontology_term_type).permit(:name, :label, :cell_ontology_ids, :in_lineage_term_ids, :term_ids, :free_text_json, :rank)
  end

  def cell_ontologies_for(collection)
    ids = collection.flat_map(&:cell_ontology_ids_list).uniq
    return {} if ids.empty?

    CellOntology.where(id: ids).index_by(&:id)
  end

  def terms_for(collection)
    ids = collection.flat_map { |record| record.lineage_term_ids_list + record.term_ids_list }.uniq
    return {} if ids.empty?

    CellOntologyTerm.where(id: ids).index_by(&:id)
  end
end

