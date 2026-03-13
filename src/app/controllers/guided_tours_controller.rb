class GuidedToursController < ApplicationController
  before_action :authorize_admin
  before_action :set_guided_tour, only: [:show, :edit, :update, :destroy]

  def index
    @guided_tours = GuidedTour.ordered
  end

  def show
    @guided_tours = GuidedTour.ordered
    @guided_tour_steps = @guided_tour.guided_tour_steps.ordered
    @new_guided_tour_step = @guided_tour.guided_tour_steps.build
  end

  def new
    @guided_tour = GuidedTour.new
  end

  def edit
  end

  def create
    @guided_tour = GuidedTour.new(guided_tour_params)
    if @guided_tour.save
      redirect_to guided_tour_path(@guided_tour), notice: 'Guided tour was successfully created.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @guided_tour.update(guided_tour_params)
      redirect_to guided_tour_path(@guided_tour), notice: 'Guided tour was successfully updated.'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @guided_tour.destroy
    redirect_to guided_tours_path, notice: 'Guided tour was successfully deleted.'
  end

  def reorder
    ids = params.require(:ordered_ids).map(&:to_i)
    tours = GuidedTour.where(id: ids).index_by(&:id)

    GuidedTour.transaction do
      ids.each_with_index do |id, index|
        tour = tours[id]
        next if tour.nil?

        tour.update!(rank: index + 1)
      end
    end

    head :ok
  end

  private

  def set_guided_tour
    @guided_tour = GuidedTour.find(params[:id])
  end

  def guided_tour_params
    params.require(:guided_tour).permit(:name, :rank, :duration_time)
  end
end
