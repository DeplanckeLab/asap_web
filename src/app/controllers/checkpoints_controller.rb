class CheckpointsController < ApplicationController
  before_action :set_project
  before_action :set_checkpoint, only: [:show, :update, :destroy]

  def index
    return if performed?
    return unless ensure_readable!

    checkpoints = @project.checkpoints.includes(:user).order(created_at: :desc)
    render json: {
      checkpoints: checkpoints.map { |checkpoint| checkpoint_payload(checkpoint, include_state: true) }
    }
  end

  def show
    return if performed?
    return unless ensure_readable!

    render json: { checkpoint: checkpoint_payload(@checkpoint, include_state: true) }
  end

  def create
    return if performed?
    return unless ensure_editable!

    checkpoint = @project.checkpoints.new
    checkpoint.user = current_user
    checkpoint.title = checkpoint_title
    checkpoint.state = checkpoint_state
    checkpoint.comments = []

    if checkpoint.save
      render json: { checkpoint: checkpoint_payload(checkpoint, include_state: true) }, status: :created
    else
      render json: { error: checkpoint.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def update
    return if performed?
    return unless ensure_editable!

    if checkpoint_title.present?
      @checkpoint.title = checkpoint_title
    end

    if checkpoint_state_param_present?
      @checkpoint.state = checkpoint_state
    end

    if comment_body.present?
      updated_comments = @checkpoint.comments
      updated_comments << {
        user_id: current_user&.id,
        user_name: current_user&.displayed_name.presence || current_user&.email,
        body: comment_body,
        created_at: Time.current.iso8601
      }
      @checkpoint.comments = updated_comments
    end

    if @checkpoint.save
      render json: { checkpoint: checkpoint_payload(@checkpoint, include_state: true) }
    else
      render json: { error: @checkpoint.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def destroy
    return if performed?
    return unless ensure_editable!

    @checkpoint.destroy
    render json: { success: true }
  end

  private

  def set_project
    project_identifier = params[:project_id].to_s
    @project = Project.find_by(id: project_identifier) ||
               Project.find_by(key: project_identifier) ||
               Project.find_by(public_id: project_identifier)
    return if @project

    render json: { error: 'Project not found' }, status: :not_found
  end

  def set_checkpoint
    return if performed?

    @checkpoint = @project.checkpoints.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Checkpoint not found' }, status: :not_found
  end

  def checkpoint_title
    params.dig(:checkpoint, :title).to_s.strip
  end

  def checkpoint_state
    raw_state = params.dig(:checkpoint, :state)
    if raw_state.is_a?(ActionController::Parameters)
      raw_state.to_unsafe_h
    elsif raw_state.is_a?(Hash)
      raw_state
    else
      {}
    end
  end

  def checkpoint_state_param_present?
    params[:checkpoint].is_a?(ActionController::Parameters) && params[:checkpoint].key?(:state)
  end

  def comment_body
    params.dig(:checkpoint, :comment_body).to_s.strip
  end

  def ensure_readable!
    return true if @project && readable?(@project)

    render json: { error: 'Not authorized' }, status: :forbidden
    false
  end

  def ensure_editable!
    return true if @project && editable?(@project)

    render json: { error: 'Not authorized' }, status: :forbidden
    false
  end

  def checkpoint_payload(checkpoint, include_state:)
    comments = checkpoint.comments
    payload = {
      id: checkpoint.id,
      title: checkpoint.title,
      project_id: checkpoint.project_id,
      user_id: checkpoint.user_id,
      user_name: checkpoint.user&.displayed_name.presence || checkpoint.user&.email,
      comments: comments,
      comments_count: comments.length,
      created_at: checkpoint.created_at,
      updated_at: checkpoint.updated_at
    }
    payload[:state] = checkpoint.state if include_state
    payload
  end
end
