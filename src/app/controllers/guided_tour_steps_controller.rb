class GuidedTourStepsController < ApplicationController
  before_action :authorize_admin
  before_action :ensure_synced_reference_data_writable!
  before_action :set_guided_tour
  before_action :set_guided_tour_step, only: [:update, :destroy]

  def create
    @guided_tour_step = @guided_tour.guided_tour_steps.build(guided_tour_step_params)
    if @guided_tour_step.save
      redirect_to guided_tour_path(@guided_tour), notice: 'Guided tour step was successfully created.'
    else
      @guided_tours = GuidedTour.ordered
      @guided_tour_steps = @guided_tour.guided_tour_steps.ordered
      @new_guided_tour_step = @guided_tour_step
      render 'guided_tours/show', status: :unprocessable_entity
    end
  end

  def update
    if @guided_tour_step.update(guided_tour_step_params)
      redirect_to guided_tour_path(@guided_tour), notice: 'Guided tour step was successfully updated.'
    else
      @guided_tours = GuidedTour.ordered
      @guided_tour_steps = @guided_tour.guided_tour_steps.ordered
      @new_guided_tour_step = @guided_tour.guided_tour_steps.build
      render 'guided_tours/show', status: :unprocessable_entity
    end
  end

  def destroy
    @guided_tour_step.destroy
    redirect_to guided_tour_path(@guided_tour), notice: 'Guided tour step was successfully deleted.'
  end

  def reorder
    ids = params.require(:ordered_ids).map(&:to_i)
    steps = @guided_tour.guided_tour_steps.where(id: ids).index_by(&:id)

    GuidedTourStep.transaction do
      ids.each_with_index do |id, index|
        step = steps[id]
        next if step.nil?

        step.update!(rank: index + 1)
      end
    end

    head :ok
  end

  private

  def set_guided_tour
    @guided_tour = GuidedTour.find(params[:guided_tour_id])
  end

  def set_guided_tour_step
    @guided_tour_step = @guided_tour.guided_tour_steps.find(params[:id])
  end

  def guided_tour_step_params
    params.require(:guided_tour_step).permit(:rank, :page_url, :title, :focus_element, :description, :step_actions_json,
                                               :exclude_from_page_replay)
  end
end
