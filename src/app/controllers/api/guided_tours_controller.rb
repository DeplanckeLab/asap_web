# frozen_string_literal: true

module Api
  class GuidedToursController < ApplicationController
    def index
      tours = GuidedTour.ordered.select(:id, :name)
      render json: { guided_tours: tours.map { |t| { id: t.id, name: t.name } } }
    end

    def show
      tour = GuidedTour.includes(:guided_tour_steps).find(params[:id])
      steps = tour.guided_tour_steps.ordered.map do |step|
        {
          id: step.id,
          rank: step.rank,
          page_url: step.page_url,
          title: step.title,
          focus_element: step.focus_element,
          description: step.description,
          step_actions: step.step_actions,
          exclude_from_page_replay: step.exclude_from_page_replay
        }
      end
      render json: {
        id: tour.id,
        name: tour.name,
        duration_time: tour.duration_time,
        steps: steps
      }
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Not found' }, status: :not_found
    end
  end
end
