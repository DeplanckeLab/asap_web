module ProjectAuthorization
  extend ActiveSupport::Concern

  # Matches original owner/admin/sandbox/IP access semantics.
  def authorized?(project = @project)
    return false unless project

    return true if admin?
    return true if project.sandbox? && session[:sandbox] == project.key
    return true if current_user && current_user.id == project.user_id
    return true if ip_restricted_access?(project)

    false
  end

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

  # Check if user can clone/duplicate a project
  def clonable?(project)
    exportable?(project)
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

  # Check if user can analyze a project
  def analyzable?(project)
    return false unless project

    return true if admin?
    return true if project.sandbox? && session[:sandbox] == project.key
    return true if current_user && project.user_id == current_user.id

    if current_user
      share = project.shares.find_by(user_id: current_user.id)
      return true if share&.analyze_perm?
    end

    false
  end

  # Check if user can analyze an item in a project
  def analyzable_item?(project, item)
    return false unless project && item
    return true if admin? || analyzable?(project)
    return false unless analyzable?(project) && current_user

    item.respond_to?(:user_id) && item.user_id == current_user.id
  end

  # Check if user can annotate a project
  # - Public projects: logged-in user with registered ORCID
  # - Private projects: analyzable rights + logged-in user with registered ORCID
  def annotable?(project)
    return false unless project
    return false unless current_user && current_user.orcid_user_id.present?
    return true if project.public?
    analyzable?(project)
  end

  # Check if user can annotate an item in a project
  def annotable_item?(project, item)
    return false unless project && item
    return true if annotable?(project)
    return false unless annotable?(project) && current_user

    item.respond_to?(:user_id) && item.user_id == current_user.id
  end

  # Check if user can vote on CLA in a project
  def cla_votable?(project)
    annotable?(project)
  end

  # Check if user can edit a project
  def editable?(project)
    return false unless project

    owner_or_admin?(project)
  end

  # Check if user can download project data
  def downloadable?(project)
    exportable?(project)
  end

  # Check if user can delete a project (only owners and admins)
  def deletable?(project)
    return false unless project
    return true if admin?
    return true if owner?(project)
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

  def owner_or_admin_obj?(object, project)
    return true if admin?
    return false unless object && project

    return true if project.sandbox? && session[:sandbox] == project.key
    current_user && object.respond_to?(:user_id) && object.user_id == current_user.id
  end

  # Check if current user is project owner or admin
  def owner_or_admin?(project)
    return false unless project
    admin? || owner?(project)
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
    return false unless request && project

    Ip.joins('join ips_users on (ips.id = ip_id)')
      .where(
        ip: request.remote_ip,
        key: params[:ip_restricted_access_key],
        ips_users: { user_id: [project.user_id, 1] }
      )
      .exists?
  end
end

