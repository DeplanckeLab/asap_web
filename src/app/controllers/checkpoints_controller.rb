class CheckpointsController < ApplicationController
  CURRENT_VISUALIZATION_CHECKPOINT_TITLE = '__current_visualization_view__'.freeze

  before_action :set_project
  before_action :set_checkpoint, only: [:show, :update, :destroy]

  def index
    return if performed?
    return unless ensure_readable!

    checkpoints = @project.checkpoints
      .where.not(title: CURRENT_VISUALIZATION_CHECKPOINT_TITLE)
      .includes(:user)
      .order(created_at: :desc)
    render json: {
      checkpoints: checkpoints.map { |checkpoint| checkpoint_payload(checkpoint, include_state: true) }
    }
  end

  def show
    return if performed?
    return unless ensure_readable!

    render json: { checkpoint: checkpoint_payload(@checkpoint, include_state: true) }
  end

  def current
    return if performed?
    return unless ensure_readable!

    checkpoint = @project.checkpoints.find_by(title: CURRENT_VISUALIZATION_CHECKPOINT_TITLE)
    render json: {
      checkpoint: checkpoint ? checkpoint_payload(checkpoint, include_state: true) : nil
    }
  end

  def create
    return if performed?
    return unless ensure_analyzable!

    if checkpoint_title == CURRENT_VISUALIZATION_CHECKPOINT_TITLE
      render json: { error: 'Checkpoint title is reserved.' }, status: :unprocessable_entity
      return
    end

    checkpoint = @project.checkpoints.new
    checkpoint.user = current_user
    checkpoint.title = checkpoint_title
    checkpoint.state = checkpoint_state
    checkpoint.comments = []
    checkpoint.is_landing_page = checkpoint_is_landing_page if checkpoint_is_landing_page_param_present?

    saved = false
    Checkpoint.transaction do
      if checkpoint.is_landing_page?
        @project.checkpoints.where(is_landing_page: true).update_all(is_landing_page: false)
      end
      saved = checkpoint.save
      raise ActiveRecord::Rollback unless saved
    end

    if saved
      render json: { checkpoint: checkpoint_payload(checkpoint, include_state: true) }, status: :created
    else
      render json: { error: checkpoint.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def update
    return if performed?
    return unless ensure_analyzable!

    if checkpoint_title == CURRENT_VISUALIZATION_CHECKPOINT_TITLE
      render json: { error: 'Checkpoint title is reserved.' }, status: :unprocessable_entity
      return
    end

    if checkpoint_title.present?
      @checkpoint.title = checkpoint_title
    end

    if checkpoint_state_param_present?
      @checkpoint.state = checkpoint_state
    end

    if checkpoint_is_landing_page_param_present?
      is_landing_page = checkpoint_is_landing_page
      if is_landing_page
        @project.checkpoints.where(is_landing_page: true).where.not(id: @checkpoint.id).update_all(is_landing_page: false)
      end
      @checkpoint.is_landing_page = is_landing_page
    end

    updated_comments = normalize_comments(@checkpoint.comments)

    if comment_action == 'edit'
      unless edit_or_delete_checkpoint_comment!(updated_comments, :edit)
        return
      end
      @checkpoint.comments = updated_comments
    elsif comment_action == 'delete'
      unless edit_or_delete_checkpoint_comment!(updated_comments, :delete)
        return
      end
      @checkpoint.comments = updated_comments
    elsif comment_body.present?
      updated_comments << {
        id: SecureRandom.uuid,
        user_id: current_user&.id,
        user_name: current_user&.displayed_name.presence || current_user&.email,
        body: comment_body,
        created_at: Time.current.iso8601
      }
      @checkpoint.comments = updated_comments
    end

    saved = false
    Checkpoint.transaction do
      saved = @checkpoint.save
      raise ActiveRecord::Rollback unless saved
    end

    if saved
      render json: { checkpoint: checkpoint_payload(@checkpoint, include_state: true) }
    else
      render json: { error: @checkpoint.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def destroy
    return if performed?
    return unless ensure_analyzable!

    @checkpoint.destroy
    render json: { success: true }
  end

  def upsert_current
    return if performed?
    return unless ensure_analyzable!

    checkpoint = @project.checkpoints.find_or_initialize_by(title: CURRENT_VISUALIZATION_CHECKPOINT_TITLE)
    checkpoint.user = current_user
    checkpoint.state = checkpoint_state
    checkpoint.comments = []
    checkpoint.is_landing_page = false

    if checkpoint.save
      render json: { checkpoint: checkpoint_payload(checkpoint, include_state: true) }
    else
      render json: { error: checkpoint.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
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

  def checkpoint_is_landing_page_param_present?
    params[:checkpoint].is_a?(ActionController::Parameters) && params[:checkpoint].key?(:is_landing_page)
  end

  def checkpoint_is_landing_page
    ActiveModel::Type::Boolean.new.cast(params.dig(:checkpoint, :is_landing_page))
  end

  def comment_body
    params.dig(:checkpoint, :comment_body).to_s.strip
  end

  def comment_action
    params.dig(:checkpoint, :comment_action).to_s.strip
  end

  def comment_id
    params.dig(:checkpoint, :comment_id).to_s.strip
  end

  def ensure_readable!
    return true if @project && readable?(@project)

    render json: { error: 'Not authorized' }, status: :forbidden
    false
  end

  def ensure_analyzable!
    return true if @project && analyzable?(@project)

    render json: { error: 'Not authorized' }, status: :forbidden
    false
  end

  def checkpoint_payload(checkpoint, include_state:)
    comments = serialize_comments_for_payload(checkpoint.comments)
    payload = {
      id: checkpoint.id,
      title: checkpoint.title,
      project_id: checkpoint.project_id,
      user_id: checkpoint.user_id,
      user_name: checkpoint.user&.displayed_name.presence || checkpoint.user&.email,
      comments: comments,
      comments_count: comments.length,
      is_landing_page: checkpoint.is_landing_page,
      created_at: checkpoint.created_at,
      updated_at: checkpoint.updated_at
    }
    payload[:state] = checkpoint.state if include_state
    payload
  end

  def normalize_comments(comments)
    Array(comments).map do |comment|
      c = (comment || {}).deep_symbolize_keys
      c[:id] = c[:id].presence || stable_comment_id(c)
      c
    end
  end

  def stable_comment_id(comment)
    seed = [
      comment[:created_at].to_s,
      comment[:user_id].to_s,
      comment[:user_name].to_s,
      comment[:body].to_s
    ].join('|')
    Digest::SHA1.hexdigest(seed)
  end

  def serialize_comments_for_payload(comments)
    normalize_comments(comments).map do |comment|
      serialized = comment.deep_dup
      serialized[:user_can_manage] = current_user_can_manage_comment?(comment)
      serialized
    end
  end

  def current_user_can_manage_comment?(comment)
    return true if admin?
    return false unless current_user&.id
    comment_user_id = comment[:user_id] || comment['user_id']
    comment_user_id.to_i == current_user.id.to_i
  end

  def edit_or_delete_checkpoint_comment!(comments, action)
    cid = comment_id
    if cid.blank?
      render json: { error: 'Comment id is required.' }, status: :unprocessable_entity
      return false
    end

    target = comments.find { |comment| String(comment[:id]) == cid }
    unless target
      render json: { error: 'Comment not found.' }, status: :not_found
      return false
    end

    unless current_user_can_manage_comment?(target)
      render json: { error: 'Not authorized to modify this comment.' }, status: :forbidden
      return false
    end

    if action == :edit
      body = comment_body
      if body.blank?
        render json: { error: 'Comment body cannot be empty.' }, status: :unprocessable_entity
        return false
      end
      target[:body] = body
      target[:updated_at] = Time.current.iso8601
    elsif action == :delete
      comments.delete(target)
    end

    true
  end
end
