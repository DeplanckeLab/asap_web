# frozen_string_literal: true

class ProjectOwnershipTransferService
  class Error < StandardError; end

  TRANSFERABLE_KEYS = %i[
    runs
    selections
    clas
    cla_votes
    annots
    checkpoints
    gene_set_collections
    reqs
    fus
    jobs
    fos
    module_score_requests
  ].freeze

  def self.call!(project:, new_owner_email:, transfer: {}, transfer_all: false)
    new(
      project: project,
      new_owner_email: new_owner_email,
      transfer: transfer,
      transfer_all: transfer_all
    ).call!
  end

  def initialize(project:, new_owner_email:, transfer: {}, transfer_all: false)
    @project = project
    @new_owner_email = new_owner_email.to_s.strip.downcase
    @transfer_all = ActiveModel::Type::Boolean.new.cast(transfer_all)
    @transfer = normalize_transfer(transfer)
  end

  def call!
    validate!
    moved = relocate_project_filesystem!
    begin
      ActiveRecord::Base.transaction do
        reassign_related_records!
        remove_new_owner_shares!
        @project.update!(user_id: @new_owner.id)
        share_previous_owner_if_needed!
      end
    rescue StandardError
      restore_project_filesystem!(moved) if moved
      raise
    end

    {
      project: @project.reload,
      new_owner: @new_owner,
      transferred: @transfer.select { |_key, enabled| enabled }.keys,
      previous_owner_shared: @previous_owner_shared
    }
  end

  private

  def validate!
    raise Error, 'Sandbox projects cannot be transferred.' if @project.sandbox?
    raise Error, 'This project has no owner to transfer from.' if @project.user_id.blank?
    raise Error, 'Enter the email of an existing user account.' if @new_owner_email.blank?

    @from_user_id = @project.user_id
    @previous_owner = User.find_by(id: @from_user_id)
    raise Error, 'This project has no owner to transfer from.' unless @previous_owner
    @new_owner = User.find_by(email: @new_owner_email)
    raise Error, 'No user account exists for that email.' unless @new_owner
    raise Error, 'That user already owns this project.' if @new_owner.id == @from_user_id
    @previous_owner_shared = false
  end

  def normalize_transfer(transfer)
    return TRANSFERABLE_KEYS.index_with { true } if @transfer_all

    source = if transfer.respond_to?(:to_unsafe_h)
               transfer.to_unsafe_h
             elsif transfer.respond_to?(:to_h)
               transfer.to_h
             else
               {}
             end
    source = source.with_indifferent_access

    collaborative = ActiveModel::Type::Boolean.new.cast(source[:collaborative_annotations])
    TRANSFERABLE_KEYS.index_with do |key|
      selected = ActiveModel::Type::Boolean.new.cast(source[key])
      if %i[clas cla_votes].include?(key)
        selected || collaborative
      else
        selected
      end
    end
  end

  def reassign_related_records!
    TRANSFERABLE_KEYS.each do |key|
      next unless @transfer[key]

      send("transfer_#{key}!")
    end
  end

  def transfer_runs!
    @project.runs.where(user_id: @from_user_id).update_all(user_id: @new_owner.id)
  end

  def transfer_selections!
    SelectionRecord.where(project_id: @project.id, user_id: @from_user_id)
                   .update_all(user_id: @new_owner.id, updated_at: Time.current)
  end

  def transfer_clas!
    Cla.where(project_id: @project.id, user_id: @from_user_id).update_all(user_id: @new_owner.id)
  end

  def transfer_cla_votes!
    votes = ClaVote.where(cla_id: Cla.where(project_id: @project.id).select(:id), user_id: @from_user_id)
    conflicting_cla_ids = ClaVote.where(user_id: @new_owner.id, cla_id: votes.select(:cla_id)).pluck(:cla_id)
    votes = votes.where.not(cla_id: conflicting_cla_ids) if conflicting_cla_ids.any?
    votes.update_all(user_id: @new_owner.id)
  end

  def transfer_annots!
    Annot.unscoped.where(project_id: @project.id, user_id: @from_user_id).update_all(user_id: @new_owner.id)
  end

  def transfer_checkpoints!
    @project.checkpoints.where(user_id: @from_user_id).update_all(user_id: @new_owner.id)
  end

  def transfer_gene_set_collections!
    GeneSetCollection.where(project_id: @project.id, user_id: @from_user_id).update_all(user_id: @new_owner.id)
  end

  def transfer_reqs!
    @project.reqs.where(user_id: @from_user_id).update_all(user_id: @new_owner.id)
  end

  def transfer_fus!
    Fu.where(project_id: @project.id, user_id: @from_user_id).update_all(user_id: @new_owner.id)
  end

  def transfer_jobs!
    Job.where(project_id: @project.id, user_id: @from_user_id).update_all(user_id: @new_owner.id)
  end

  def transfer_fos!
    Fo.where(project_id: @project.id, user_id: @from_user_id).update_all(user_id: @new_owner.id)
  end

  def transfer_module_score_requests!
    ModuleScoreRequest.where(project_id: @project.id, user_id: @from_user_id).update_all(user_id: @new_owner.id)
  end

  def remove_new_owner_shares!
    @project.shares.where(user_id: @new_owner.id).destroy_all
    @project.shares.where('LOWER(email) = ?', @new_owner.email.to_s.downcase).destroy_all
  end

  def share_previous_owner_if_needed!
    return unless previous_owner_still_owns_records?

    share = @project.shares.find_or_initialize_by(user_id: @previous_owner.id)
    share.email = @previous_owner.email
    share.view_perm = true
    share.analyze_perm = true
    share.save!
    @previous_owner_shared = true
  end

  def previous_owner_still_owns_records?
    return true if @project.runs.where(user_id: @from_user_id).exists?
    return true if SelectionRecord.where(project_id: @project.id, user_id: @from_user_id).exists?
    return true if Cla.where(project_id: @project.id, user_id: @from_user_id).exists?
    return true if ClaVote.where(cla_id: Cla.where(project_id: @project.id).select(:id), user_id: @from_user_id).exists?
    return true if Annot.unscoped.where(project_id: @project.id, user_id: @from_user_id).exists?
    return true if @project.checkpoints.where(user_id: @from_user_id).exists?
    return true if GeneSetCollection.where(project_id: @project.id, user_id: @from_user_id).exists?
    return true if @project.reqs.where(user_id: @from_user_id).exists?
    return true if Fu.where(project_id: @project.id, user_id: @from_user_id).exists?
    return true if Job.where(project_id: @project.id, user_id: @from_user_id).exists?
    return true if Fo.where(project_id: @project.id, user_id: @from_user_id).exists?
    return true if ModuleScoreRequest.where(project_id: @project.id, user_id: @from_user_id).exists?

    false
  end

  def relocate_project_filesystem!
    paths = filesystem_paths
    return nil unless File.exist?(paths[:old_dir].to_s) || File.exist?(paths[:old_archive].to_s)

    if File.exist?(paths[:new_dir].to_s)
      raise Error, 'A project directory already exists for the new owner at the destination path.'
    end
    if File.exist?(paths[:new_archive].to_s)
      raise Error, 'A project archive already exists for the new owner at the destination path.'
    end

    FileUtils.mkdir_p(paths[:new_parent].to_s)
    FileUtils.mv(paths[:old_dir].to_s, paths[:new_dir].to_s) if File.exist?(paths[:old_dir].to_s)
    FileUtils.mv(paths[:old_archive].to_s, paths[:new_archive].to_s) if File.exist?(paths[:old_archive].to_s)
    paths
  end

  def restore_project_filesystem!(paths)
    FileUtils.mv(paths[:new_dir].to_s, paths[:old_dir].to_s) if File.exist?(paths[:new_dir].to_s) && !File.exist?(paths[:old_dir].to_s)
    FileUtils.mv(paths[:new_archive].to_s, paths[:old_archive].to_s) if File.exist?(paths[:new_archive].to_s) && !File.exist?(paths[:old_archive].to_s)
  end

  def filesystem_paths
    root = Pathname.new(ENV['USER_DATA_DIR'] || Rails.root.join('storage', 'user_data').to_s).cleanpath
    old_dir = (root + @from_user_id.to_s + @project.key).cleanpath
    new_parent = (root + @new_owner.id.to_s).cleanpath
    new_dir = (new_parent + @project.key).cleanpath

    unless old_dir.to_s.start_with?("#{root}/") && new_dir.to_s.start_with?("#{root}/")
      raise Error, 'Refused unsafe project data path for ownership transfer.'
    end
    unless old_dir.basename.to_s == @project.key && new_dir.basename.to_s == @project.key
      raise Error, 'Refused unsafe project data path for ownership transfer.'
    end

    {
      old_dir: old_dir,
      new_dir: new_dir,
      new_parent: new_parent,
      old_archive: Pathname.new("#{old_dir}.tgz"),
      new_archive: Pathname.new("#{new_dir}.tgz")
    }
  end

  class SelectionRecord < ApplicationRecord
    self.table_name = 'selections'
  end
end
