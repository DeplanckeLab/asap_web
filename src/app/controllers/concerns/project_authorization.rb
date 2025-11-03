module ProjectAuthorization
  extend ActiveSupport::Concern

  # Check if user can read/view a project
  # Allows: admins, owners, public projects, sandbox projects (via session), shared projects, IP-restricted access
  def readable?(project)
    return false unless project

    # Admin always has access
    return true if admin?

    # IP-restricted access
    return true if ip_restricted_access?(project)

    # Sandbox projects with session key (no auth required)
    if project.sandbox? && session[:sandbox] == project.key
      return true
    end

    # Public projects (no auth required)
    return true if project.public?

    # Owner access (requires auth)
    return true if current_user && project.user_id == current_user.id

    # Shared project access (requires auth)
    if current_user
      share = project.shares.find_by(user_id: current_user.id)
      return true if share&.view_perm?
    end

    false
  end

  # Check if user can export/download project data
  def exportable?(project)
    return false unless project

    # Admin always has access
    return true if admin?

    # IP-restricted access
    return true if ip_restricted_access?(project)

    # Sandbox projects with session key
    if project.sandbox? && session[:sandbox] == project.key
      return true
    end

    # Public projects
    return true if project.public?

    # Owner access
    return true if current_user && project.user_id == current_user.id

    # Shared project with export permission
    if current_user
      share = project.shares.find_by(user_id: current_user.id)
      return true if share&.export_perm?
    end

    false
  end

  # Check if user can export a specific item (run, etc.)
  def exportable_item?(project, item)
    return false unless project && item

    # If user can edit or export the project, they can export items
    return true if editable?(project) || exportable?(project)

    # If user owns the item
    return true if current_user && item.respond_to?(:user_id) && item.user_id == current_user.id

    false
  end

  # Check if user can edit a project
  def editable?(project)
    return false unless project

    return true if admin?

    # Sandbox projects with session key
    if project.sandbox? && session[:sandbox] == project.key
      return true
    end

    # Owner access
    return true if current_user && project.user_id == current_user.id

    # Shared project with analyze permission
    if current_user
      share = project.shares.find_by(user_id: current_user.id)
      return true if share&.analyze_perm?
    end

    false
  end

  # Check if user owns a project
  def owner?(project)
    return false unless project

    # Sandbox projects with session key (temporary ownership)
    return true if project.sandbox? && session[:sandbox] == project.key

    # Actual owner
    return true if current_user && project.user_id == current_user.id

    false
  end

  # Check if project is read-only for current user
  def read_only?(project)
    return true unless project
    return false if admin?

    # Sandbox projects are not read-only if session matches
    return false if project.sandbox? && session[:sandbox] == project.key

    # Public projects are read-only for non-owners
    return true if project.public? && !owner?(project)

    # Non-owners without edit permission
    if current_user && project.user_id != current_user.id
      share = project.shares.find_by(user_id: current_user.id)
      return true unless share&.analyze_perm?
    end

    # Non-authenticated users
    return true unless current_user

    false
  end

  private

  # Check IP-restricted access (if implemented)
  def ip_restricted_access?(project)
    # This would check if the request IP matches an allowed IP for the project
    # For now, return false - can be implemented later if needed
    # Example: Ip.joins('join ips_users on (ips.id = ip_id)')
    #   .where(:ip => request.remote_ip, :key => params[:ip_restricted_access_key], 
    #          :ips_users => {:user_id => [project.user_id, 1]}).count > 0
    false
  end
end

