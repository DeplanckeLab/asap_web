class SharesController < ApplicationController
  before_action :set_share, only: [:show, :update, :destroy]

  # POST /shares/batch_add
  def batch_add
    @project = Project.find_by(key: params[:project_key])
    
    unless @project && (admin? || @project.user_id == current_user&.id)
      render json: { success: false, error: 'Unauthorized' }, status: :unauthorized
      return
    end

    emails = params[:batch_emails].to_s.split(/[,;\s\n]+/).compact.uniq.map(&:downcase).reject(&:blank?)
    added_count = 0
    
    emails.each do |email|
      user = User.find_by(email: email)
      existing_share = Share.find_by(
        user_id: user&.id,
        email: email,
        project_id: @project.id
      )
      
      if existing_share
        # Update existing share permissions
        existing_share.update(
          analyze_perm: params[:batch_analyze_perm],
          export_perm: params[:batch_export_perm]
        )
      else
        # Create new share
        share = Share.new(
          user_id: user&.id,
          email: email,
          project_id: @project.id,
          view_perm: true,
          analyze_perm: params[:batch_analyze_perm],
          export_perm: params[:batch_export_perm]
        )
        added_count += 1 if share.save
      end
    end

    render json: { success: true, added: added_count }
  end

  # POST /shares
  def create
    @project = Project.find_by(key: params[:project_key])
    
    unless @project && (admin? || @project.user_id == current_user&.id)
      render json: { success: false, error: 'Unauthorized' }, status: :unauthorized
      return
    end

    email = share_params[:email].to_s.downcase.strip
    user = User.find_by(email: email)
    
    existing_share = Share.find_by(
      email: email,
      project_id: @project.id
    )

    if existing_share
      render json: { success: false, error: 'User already has access to this project' }
      return
    end

    @share = Share.new(share_params)
    @share.project_id = @project.id
    @share.user_id = user&.id
    @share.email = email
    @share.view_perm = true

    if @share.save
      render json: { success: true, share: { id: @share.id, email: @share.email } }
    else
      render json: { success: false, error: @share.errors.full_messages.join(', ') }
    end
  end

  # PATCH/PUT /shares/1
  def update
    unless can_manage_share?(@share)
      render json: { success: false, error: 'Unauthorized' }, status: :unauthorized
      return
    end

    if @share.update(share_params)
      render json: { success: true }
    else
      render json: { success: false, error: @share.errors.full_messages.join(', ') }
    end
  end

  # DELETE /shares/1
  def destroy
    unless can_manage_share?(@share)
      render json: { success: false, error: 'Unauthorized' }, status: :unauthorized
      return
    end

    @share.destroy
    render json: { success: true }
  end

  private

  def set_share
    @share = Share.find(params[:id])
  end

  def share_params
    params.require(:share).permit(:email, :view_perm, :analyze_perm, :export_perm, :download_perm)
  end

  def can_manage_share?(share)
    return true if admin?
    return false unless current_user
    share.project&.user_id == current_user.id
  end
end


